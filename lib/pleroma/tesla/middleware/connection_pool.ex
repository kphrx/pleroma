# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Tesla.Middleware.ConnectionPool do
  @moduledoc """
  Middleware to get/release connections from `Pleroma.Gun.ConnectionPool`
  """

  @behaviour Tesla.Middleware

  alias Pleroma.Gun.ConnectionPool

  @impl Tesla.Middleware
  def call(%Tesla.Env{opts: opts} = env, next, middleware_opts) do
    if opts[:adapter][:body_as] == :stream do
      {:error, :pooled_streaming_requires_chunks}
    else
      do_call(env, next, middleware_opts)
    end
  end

  defp do_call(%Tesla.Env{url: url, opts: opts} = env, next, _) do
    uri = URI.parse(url)

    # Avoid leaking connections when the middleware is called twice
    # with body_as: :chunks. We assume only the middleware can set
    # opts[:adapter][:conn]
    cleanup_previous_request(env)

    case ConnectionPool.get_conn(uri, opts[:adapter]) do
      {:ok, conn_pid} ->
        tunnel = ConnectionPool.tunnel_ref(conn_pid)

        adapter_opts =
          opts[:adapter]
          |> Keyword.drop([:conn, :stream, :tunnel])
          |> Keyword.merge(conn: conn_pid, close_conn: false, tunnel: tunnel)

        opts = Keyword.put(opts, :adapter, adapter_opts)
        env = %{env | opts: opts}
        next = use_pool_adapter(next)

        case Tesla.run(env, next) do
          {:ok, env} ->
            unless opts[:adapter][:body_as] == :chunks and chunk_client?(env.body) do
              ConnectionPool.release_conn(conn_pid)
              {_, res} = pop_in(env.opts[:adapter][:conn])
              {:ok, res}
            else
              {:ok, env}
            end

          {:error, {:gun_stream_error, reason}} ->
            {:error, reason}

          err ->
            ConnectionPool.discard_conn(conn_pid)
            err
        end

      err ->
        err
    end
  end

  defp cleanup_previous_request(%Tesla.Env{
         body: %{pid: pid, stream: stream},
         opts: opts
       }) do
    if opts[:adapter][:conn], do: ConnectionPool.cancel_stream(pid, stream)
  end

  defp cleanup_previous_request(%Tesla.Env{opts: opts}) do
    conn = opts[:adapter][:conn]
    stream = opts[:adapter][:stream]

    cond do
      conn && stream -> ConnectionPool.cancel_stream(conn, stream)
      conn -> ConnectionPool.release_conn(conn)
      true -> :ok
    end
  end

  defp chunk_client?(%{pid: pid, stream: stream}) when is_pid(pid) and not is_nil(stream),
    do: true

  defp chunk_client?(_body), do: false

  defp use_pool_adapter(next) do
    List.update_at(next, -1, fn
      {Tesla.Adapter.Gun, function, args} -> {Pleroma.HTTP.Adapter.Gun, function, args}
      adapter -> adapter
    end)
  end
end
