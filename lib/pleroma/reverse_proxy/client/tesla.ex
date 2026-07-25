# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxy.Client.Tesla do
  @behaviour Pleroma.ReverseProxy.Client

  alias Pleroma.Gun.ConnectionPool
  alias Pleroma.HTTP.AdapterHelper

  @type headers() :: [{String.t(), String.t()}]
  @type status() :: pos_integer()

  @spec request(atom(), String.t(), headers(), String.t(), keyword()) ::
          {:ok, status(), headers}
          | {:ok, status(), headers, map()}
          | {:error, atom() | String.t()}
          | no_return()

  @impl true
  def request(method, url, headers, body, opts \\ []) do
    check_adapter()

    # MediaProxyController inserts MediaProxy proxy configuration into the ReverseProxy call.
    # This config can be unformatted and in String representation, while this works for Hackney,
    # it does not work for Tesla and the proxy needs to be reformatted.
    # Gun AdapterHelper doesn't do it, since it does not overwrite proxy config.
    proxy = AdapterHelper.format_proxy(opts[:proxy])
    opts = if proxy, do: Keyword.put(opts, :proxy, proxy), else: opts

    opts = Keyword.put(opts, :body_as, :chunks)

    with {:ok, response} <-
           Pleroma.HTTP.request(
             method,
             url,
             body,
             headers,
             opts
           ) do
      if is_map(response.body) and method != :head do
        {:ok, response.status, response.headers, response.body}
      else
        conn_pid = response.opts[:adapter][:conn]
        ConnectionPool.release_conn(conn_pid)
        {:ok, response.status, response.headers}
      end
    else
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  @spec stream_body(map()) ::
          {:ok, binary(), map()} | {:error, atom() | String.t()} | :done | no_return()
  def stream_body(%{pid: pid, stream: stream, fin: true}) do
    ConnectionPool.release_stream(pid, stream)
    :done
  end

  def stream_body(client) do
    case read_chunk!(client) do
      {:fin, body} ->
        {:ok, body, Map.put(client, :fin, true)}

      {:nofin, part} ->
        {:ok, part, client}

      {:error, error} ->
        {:error, error}
    end
  end

  defp read_chunk!(%{pid: pid, stream: stream, opts: opts}) do
    adapter = check_adapter()
    adapter.read_chunk(pid, stream, opts)
  end

  @impl true
  @spec close(map) :: :ok | no_return()
  def close(%{pid: pid, stream: stream}) do
    ConnectionPool.cancel_stream(pid, stream)
  end

  def close(%{pid: pid}) do
    ConnectionPool.release_conn(pid)
  end

  defp check_adapter do
    adapter = Application.get_env(:tesla, :adapter)

    unless adapter == Tesla.Adapter.Gun do
      raise "#{adapter} doesn't support reading body in chunks"
    end

    adapter
  end
end
