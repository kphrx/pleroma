# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxy.Client.Hackney do
  @behaviour Pleroma.ReverseProxy.Client
  @redirect_limit 5

  require Logger

  # In-app redirect handler to avoid Hackney redirect bugs:
  # - https://github.com/benoitc/hackney/issues/527 (relative/protocol-less redirects can crash Hackney)
  # - https://github.com/benoitc/hackney/issues/273 (redirects not followed when using HTTP proxy)
  #
  # Based on a redirect handler from Pleb, slightly modified to work with Hackney:
  # https://declin.eu/objects/d4f38e62-5429-4614-86d1-e8fc16e6bf33
  @redirect_statuses [301, 302, 303, 307, 308]
  defp absolute_redirect_url(original_url, resp_headers) do
    location =
      Enum.find(resp_headers, fn {header, _location} ->
        String.downcase(header) == "location"
      end)

    URI.merge(original_url, elem(location, 1))
    |> URI.to_string()
  end

  @impl true
  def request(method, url, headers, body, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:path_encode_fun, fn path -> path end)
      |> Pleroma.HTTP.TLS.put_hackney_ssl_options()

    if opts[:follow_redirect] != false do
      {_state, req_opts} = Access.get_and_update(opts, :follow_redirect, fn a -> {a, false} end)
      env = %{method: method, headers: headers, body: body, req_opts: req_opts}
      res = do_request(method, url, headers, body, req_opts)

      case res do
        {:ok, code, resp_headers, client} when code in @redirect_statuses ->
          close(client)
          redirect(url, resp_headers, env, @redirect_limit)

        {:ok, code, resp_headers} when code in @redirect_statuses ->
          redirect(url, resp_headers, env, @redirect_limit)

        _ ->
          res
      end
    else
      do_request(method, url, headers, body, opts)
    end
  end

  @impl true
  def stream_body(%{released: true}), do: :done

  def stream_body(%{ref: ref, recv_timeout: recv_timeout} = client) do
    _ = :hackney.stream_next(ref)

    case receive_response(ref, recv_timeout) do
      {:ok, data} when is_binary(data) ->
        {:ok, data, client}

      # Reaching the end of the body does not free the connection: Hackney parks
      # a finished conn instead of stopping it, and an unpooled one has neither
      # an idle timeout nor a live owner monitor to reap it, so it would sit
      # there forever pinning every binary it read. Release it here, mirroring
      # what the gun client does, so callers only close what they abandon.
      {:ok, :done} ->
        close(client)
        :done

      {:error, error} ->
        {:error, error}
    end
  end

  def stream_body(ref) do
    case :hackney.stream_body(ref) do
      :done -> :done
      {:ok, data} -> {:ok, data, ref}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def close(%{released: true}), do: :ok

  def close(%{ref: ref}), do: :hackney.close(ref)

  def close(ref), do: :hackney.close(ref)

  defp do_request(method, url, headers, body, opts) do
    recv_timeout = Keyword.get(opts, :recv_timeout, :infinity)

    req_opts =
      opts
      |> Keyword.put(:async, :once)
      |> Keyword.put(:stream_to, self())

    with {:ok, ref} <- :hackney.request(method, url, headers, body, req_opts) do
      result =
        with {:ok, {:status, code, _reason}} <- receive_response(ref, recv_timeout),
             {:ok, {:headers, resp_headers}} <- receive_response(ref, recv_timeout) do
          {:ok, code, resp_headers, build_client(ref, recv_timeout, method, code, opts)}
        end

      case result do
        {:ok, _, _, _} = response ->
          response

        error ->
          close(ref)
          flush_responses(ref)
          error
      end
    end
  end

  # A response that cannot carry a body (204, 304, or a reply to HEAD) is
  # complete as soon as the headers are parsed. Hackney queues `done` for us and,
  # if the connection is pooled, checks it straight back in, so the ref stops
  # being ours at that point: pulling the stream or stopping the connection
  # afterwards would disturb whichever request checks it out next. Mark it so
  # `stream_body/1` and `close/1` leave it alone.
  #
  # This relies on hackney never running its own redirect handling for us --
  # `request/5` forces `follow_redirect: false` -- otherwise a redirect status
  # would be checked back in too and would need the same treatment.
  defp build_client(ref, recv_timeout, method, code, opts) do
    client = %{ref: ref, recv_timeout: recv_timeout}

    if released?(method, code) and pooled?(opts) do
      flush_responses(ref)
      Map.put(client, :released, true)
    else
      client
    end
  end

  defp released?(method, _code) when method in [:head, :HEAD, "head", "HEAD"], do: true
  defp released?(_method, code) when code in [204, 304], do: true
  defp released?(_method, _code), do: false

  # Mirrors hackney's own pooling decision: :hackney.use_pool/1, plus the fact
  # that a proxy tunnel always bypasses the pool. An unpooled connection is never
  # checked in, and parks in `connected` with no idle timeout, so it leaks
  # forever unless we stop it ourselves.
  defp pooled?(opts) do
    no_proxy?(Keyword.get(opts, :proxy)) and use_pool?(Keyword.get(opts, :pool))
  end

  # Hackney reads `false` as "no proxy", same as an absent option.
  defp no_proxy?(nil), do: true
  defp no_proxy?(false), do: true
  defp no_proxy?(_proxy), do: false

  defp use_pool?(false), do: false
  defp use_pool?(nil), do: Application.get_env(:hackney, :use_default_pool, true)
  defp use_pool?(_pool_name), do: true

  defp receive_response(ref, recv_timeout) do
    receive do
      {:hackney_response, ^ref, {:error, error}} -> {:error, error}
      {:hackney_response, ^ref, response} -> {:ok, response}
    after
      recv_timeout -> {:error, :timeout}
    end
  end

  defp flush_responses(ref) do
    receive do
      {:hackney_response, ^ref, _response} -> flush_responses(ref)
    after
      0 -> :ok
    end
  end

  defp redirect(url, resp_headers, env, limit) when limit == 0 do
    new_url = absolute_redirect_url(url, resp_headers)

    Logger.debug(
      "#{__MODULE__}: Handling redirect #{url} -> #{new_url}; redirect limit was reached - returning response after final redirect"
    )

    do_request(env.method, new_url, env.headers, env.body, env.req_opts)
  end

  defp redirect(url, resp_headers, env, limit) do
    new_url = absolute_redirect_url(url, resp_headers)
    Logger.debug("#{__MODULE__}: handling redirect #{url} -> #{new_url}; limit = #{limit}")

    res = do_request(env.method, new_url, env.headers, env.body, env.req_opts)

    case res do
      {:ok, code, new_resp_headers, client} when code in @redirect_statuses ->
        close(client)
        redirect(new_url, new_resp_headers, env, limit - 1)

      {:ok, code, new_resp_headers} when code in @redirect_statuses ->
        redirect(new_url, new_resp_headers, env, limit - 1)

      _ ->
        res
    end
  end
end
