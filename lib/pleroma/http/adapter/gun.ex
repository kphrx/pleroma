# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.Adapter.Gun do
  @behaviour Tesla.Adapter

  alias Pleroma.Gun.ConnectionPool
  alias Tesla.Multipart

  @default_timeout 1_000

  @impl Tesla.Adapter
  def call(env, opts) do
    adapter_opts =
      Tesla.Adapter.opts(
        [close_conn: true, body_as: :plain, send_body: :at_once, receive: true],
        env,
        opts
      )
      |> Map.new()

    with {:ok, status, headers, body} <- request(env, adapter_opts) do
      env = %{env | status: status, headers: format_headers(headers), body: body}
      {:ok, put_stream_ref(env, body)}
    end
  end

  defp put_stream_ref(env, %{stream: stream}) do
    put_in(env.opts[:adapter][:stream], stream)
  end

  defp put_stream_ref(env, _body), do: env

  defp request(env, %{conn: conn, tunnel: tunnel} = opts) do
    uri = URI.parse(Tesla.build_url(env))
    path = request_path(uri, tunnel)
    method = Tesla.Adapter.Shared.format_method(env.method)
    {headers, body, send_body} = prepare_body(env.headers, env.body, opts[:send_body])
    headers = maybe_add_forward_proxy_headers(headers, uri, opts, tunnel)
    request_opts = request_opts(opts[:reply_to], tunnel)

    stream =
      try do
        open_stream(conn, method, path, headers, body, request_opts, send_body)
      catch
        kind, reason ->
          ConnectionPool.release_conn(conn)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    :ok = ConnectionPool.register_stream(conn, stream)
    :ok = send_stream_body(conn, stream, body, send_body)
    response = read_response(conn, stream, opts)

    case response do
      {:error, reason} ->
        ConnectionPool.cancel_stream(conn, stream)
        {:error, {:gun_stream_error, reason}}

      response ->
        unless opts[:body_as] in [:chunks, :stream] and stream_body?(response) do
          :ok = ConnectionPool.finish_stream(conn, stream)
        end

        if opts[:close_conn] and opts[:body_as] not in [:stream, :chunks] do
          :gun.close(conn)
        end

        response
    end
  end

  defp stream_body?({:ok, _status, _headers, %{stream: _stream}}), do: true
  defp stream_body?({:ok, _status, _headers, %Stream{}}), do: true
  defp stream_body?(_response), do: false

  defp request_opts(reply_to, nil), do: %{reply_to: reply_to || self()}

  defp request_opts(reply_to, :forward_proxy), do: %{reply_to: reply_to || self()}

  defp request_opts(reply_to, tunnel) do
    %{reply_to: reply_to || self(), tunnel: tunnel}
  end

  defp request_path(uri, :forward_proxy) do
    path = Tesla.Adapter.Shared.prepare_path(uri.path, uri.query)
    "#{uri.scheme}://#{authority(uri)}#{path}"
  end

  defp request_path(uri, _tunnel) do
    Tesla.Adapter.Shared.prepare_path(uri.path, uri.query)
  end

  defp maybe_add_forward_proxy_headers(headers, uri, opts, :forward_proxy) do
    headers
    |> put_header_new("host", authority(uri))
    |> maybe_put_proxy_authorization(opts)
  end

  defp maybe_add_forward_proxy_headers(headers, _uri, _opts, _tunnel), do: headers

  defp maybe_put_proxy_authorization(headers, %{proxy_auth: {username, password}})
       when is_binary(username) and is_binary(password) do
    value = "Basic " <> Base.encode64(username <> ":" <> password)
    List.keystore(headers, "proxy-authorization", 0, {"proxy-authorization", value})
  end

  defp maybe_put_proxy_authorization(headers, _opts), do: headers

  defp put_header_new(headers, name, value) do
    if List.keymember?(headers, name, 0), do: headers, else: [{name, value} | headers]
  end

  defp authority(%URI{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp prepare_body(headers, %Multipart{} = multipart, _send_body) do
    {format_headers(headers ++ Multipart.headers(multipart)), Multipart.body(multipart), :stream}
  end

  defp prepare_body(headers, body, _send_body)
       when is_struct(body, Stream) or is_function(body) do
    {format_headers(headers), body, :stream}
  end

  defp prepare_body(headers, body, send_body) do
    {format_headers(headers), body || "", send_body}
  end

  defp open_stream(conn, method, path, headers, _body, request_opts, :stream) do
    :gun.headers(conn, method, path, headers, request_opts)
  end

  defp open_stream(conn, method, path, headers, body, request_opts, :at_once) do
    :gun.request(conn, method, path, headers, body, request_opts)
  end

  defp send_stream_body(conn, stream, body, :stream) do
    try do
      for data <- body, do: :ok = :gun.data(conn, stream, :nofin, data)
      :gun.data(conn, stream, :fin, "")
    catch
      kind, reason ->
        ConnectionPool.cancel_stream(conn, stream)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp send_stream_body(_conn, _stream, _body, :at_once), do: :ok

  defp read_response(conn, stream, opts) do
    receive? = opts[:receive]

    receive do
      {:gun_response, ^conn, ^stream, :fin, status, headers} ->
        {:ok, status, headers, ""}

      {:gun_response, ^conn, ^stream, :nofin, status, headers} ->
        format_response(conn, stream, opts, status, headers, opts[:body_as])

      {:gun_up, ^conn, _protocol} when receive? ->
        read_response(conn, stream, opts)

      {:gun_error, ^conn, reason} ->
        {:error, reason}

      {:gun_error, ^conn, ^stream, reason} ->
        {:error, reason}

      {:gun_down, ^conn, _protocol, _reason, _killed_streams} when receive? ->
        read_response(conn, stream, opts)

      {:DOWN, _ref, :process, ^conn, reason} ->
        {:error, reason}
    after
      opts[:timeout] || @default_timeout -> {:error, :recv_response_timeout}
    end
  end

  defp format_response(conn, stream, opts, status, headers, :plain) do
    case read_body(conn, stream, opts) do
      {:ok, body} ->
        {:ok, status, headers, body}

      {:error, error} ->
        :ok = :gun.flush(stream)
        {:error, error}
    end
  end

  defp format_response(conn, stream, opts, status, headers, :stream) do
    body =
      Stream.resource(
        fn -> :reading end,
        fn
          :reading ->
            case Tesla.Adapter.Gun.read_chunk(conn, stream, opts) do
              {:nofin, part} -> {[part], :reading}
              {:fin, part} -> {[part], :done}
              {:error, reason} -> raise "Gun stream failed: #{inspect(reason)}"
            end

          :done ->
            {:halt, :done}
        end,
        fn _state ->
          if opts[:close_conn], do: :gun.close(conn)
        end
      )

    {:ok, status, headers, body}
  end

  defp format_response(conn, stream, opts, status, headers, :chunks) do
    {:ok, status, headers, %{pid: conn, stream: stream, opts: Map.to_list(opts)}}
  end

  defp read_body(conn, stream, opts, acc \\ "") do
    receive do
      {:gun_data, ^conn, ^stream, :fin, body} ->
        append_body(acc, body, opts[:max_body])

      {:gun_data, ^conn, ^stream, :nofin, body} ->
        with {:ok, acc} <- append_body(acc, body, opts[:max_body]) do
          read_body(conn, stream, opts, acc)
        end

      {:gun_error, ^conn, ^stream, reason} ->
        {:error, reason}

      {:DOWN, _ref, :process, ^conn, reason} ->
        {:error, reason}
    after
      opts[:timeout] || @default_timeout -> {:error, :recv_body_timeout}
    end
  end

  defp append_body(acc, part, nil), do: {:ok, acc <> part}

  defp append_body(acc, part, limit) do
    body = acc <> part
    if byte_size(body) <= limit, do: {:ok, body}, else: {:error, :body_too_large}
  end

  defp format_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.downcase(to_string(key)), to_string(value)}
    end)
  end
end
