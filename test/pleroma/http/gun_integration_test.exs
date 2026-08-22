# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.GunIntegrationTest do
  use ExUnit.Case, async: false
  use Pleroma.Tests.Helpers

  alias Pleroma.Tesla.Middleware.ConnectionPool

  setup do
    clear_config([Pleroma.Gun], Pleroma.Gun.API)
    clear_config([:connections_pool, :max_idle_time], 1_000)

    origin = start_tls_origin(self())
    connect_proxy = start_connect_proxy(self())
    forward_proxy = start_forward_proxy(self())
    socks_proxy = start_socks5_proxy(self())

    on_exit(fn ->
      Process.sleep(20)
      stop_server(socks_proxy)
      stop_server(forward_proxy)
      stop_server(connect_proxy)
      stop_server(origin)
    end)

    {:ok,
     origin: origin,
     connect_proxy: connect_proxy,
     forward_proxy: forward_proxy,
     socks_proxy: socks_proxy}
  end

  test "requests HTTPS directly on a non-standard port", %{origin: origin} do
    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} = request(origin.base_url <> "/final")
  end

  test "follows redirects through an authenticated CONNECT proxy", %{
    origin: origin,
    connect_proxy: proxy
  } do
    proxy_opts = [
      proxy: {~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"}
    ]

    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} =
             request(origin.base_url <> "/redirect", proxy_opts, true)

    expected = "Basic " <> Base.encode64("alice:secret")
    assert_receive {:connect_proxy, ^expected, "127.0.0.1", origin_port}
    assert origin_port == origin.port
  end

  test "requests through an authenticated CONNECT proxy", %{
    origin: origin,
    connect_proxy: proxy
  } do
    proxy_opts = [
      proxy: {~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"}
    ]

    result = request(origin.base_url <> "/final", proxy_opts)

    expected = "Basic " <> Base.encode64("alice:secret")
    assert_receive {:connect_proxy, ^expected, "127.0.0.1", origin_port}
    assert origin_port == origin.port
    assert worker_protocol(origin.port) == :http
    assert_receive {:origin_request, "/final"}
    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} = result
  end

  test "requests HTTP through a forwarding proxy", %{forward_proxy: proxy} do
    proxy_opts = [proxy: {~c"127.0.0.1", proxy.port}]
    url = "http://origin.example:8080/final?key=value"

    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} = request(url, proxy_opts)

    assert_receive {:forward_proxy, ^url, "origin.example:8080", nil}
  end

  test "authenticates HTTP requests to a forwarding proxy", %{forward_proxy: proxy} do
    proxy_opts = [
      proxy: {~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"}
    ]

    url = "http://origin.example/final"
    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} = request(url, proxy_opts)

    expected = "Basic " <> Base.encode64("alice:secret")
    assert_receive {:forward_proxy, ^url, "origin.example", ^expected}
  end

  test "opens a request-ready authenticated CONNECT tunnel", %{
    origin: origin,
    connect_proxy: proxy
  } do
    uri = URI.parse(origin.base_url <> "/final")

    opts = [
      proxy: {~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"},
      tls_opts: [verify: :verify_none],
      connect_timeout: 2_000
    ]

    assert {:ok, conn, :http, tunnel} = Pleroma.Gun.Conn.open(uri, opts)
    stream = :gun.get(conn, "/final", [], %{tunnel: tunnel})
    assert {:response, :nofin, 200, _headers} = :gun.await(conn, stream, 2_000)
    assert {:ok, "ok"} = :gun.await_body(conn, stream, 2_000)
    :gun.close(conn)
  end

  test "streams chunks through an authenticated CONNECT tunnel", %{
    origin: origin,
    connect_proxy: proxy
  } do
    proxy_opts = [
      proxy: {~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"}
    ]

    assert {:ok, %Tesla.Env{status: 200, body: client}} =
             request_chunks(origin.base_url <> "/chunks", proxy_opts)

    assert collect_chunks(client) == "hello"
    assert :ok = Pleroma.Gun.ConnectionPool.release_conn(client.pid)
  end

  test "discards an unfinished HTTP/1 redirect stream before following it", %{
    origin: origin,
    connect_proxy: proxy
  } do
    proxy_opts = [
      proxy: {~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"}
    ]

    assert {:ok, %Tesla.Env{status: 200, body: client}} =
             request_chunks(origin.base_url <> "/redirect_chunks", proxy_opts, true)

    assert collect_chunks(client) == "hello"
    assert :ok = Pleroma.Gun.ConnectionPool.release_conn(client.pid)

    expected = "Basic " <> Base.encode64("alice:secret")
    assert_receive {:connect_proxy, ^expected, "127.0.0.1", _port}
    assert_receive {:connect_proxy, ^expected, "127.0.0.1", _port}
  end

  test "uploads multipart bodies through an authenticated CONNECT tunnel", %{
    origin: origin,
    connect_proxy: proxy
  } do
    proxy_opts = [
      proxy: {~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"}
    ]

    multipart = Tesla.Multipart.new() |> Tesla.Multipart.add_field("name", "value")

    assert {:ok, %Tesla.Env{status: 200}} =
             request_multipart(origin.base_url <> "/upload", multipart, proxy_opts)

    assert_receive {:origin_headers, "/upload", headers}
    assert String.downcase(headers) =~ "content-type: multipart/form-data;"
    assert_receive {:origin_body, "/upload", body}
    assert body =~ "name=\"name\""
    assert body =~ "value"
  end

  test "uploads streamed bodies through an authenticated CONNECT tunnel", %{
    origin: origin,
    connect_proxy: proxy
  } do
    proxy_opts = [
      proxy: {~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"}
    ]

    body = Stream.map(["streamed", "-body"], & &1)

    assert {:ok, %Tesla.Env{status: 200}} =
             request_stream(origin.base_url <> "/upload", body, proxy_opts)

    assert_receive {:origin_body, "/upload", "streamed-body"}
  end

  test "discards a partial HTTP/1 upload when body enumeration raises", %{origin: origin} do
    body =
      Stream.map(["partial", "raise"], fn
        "raise" -> raise "upload failed"
        part -> part
      end)

    assert_raise RuntimeError, "upload failed", fn ->
      request_stream(origin.base_url <> "/upload", body, [])
    end

    assert_receive {:origin_headers, "/upload", _headers}
    assert worker_protocol(origin.port) == nil

    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} = request(origin.base_url <> "/final")
  end

  test "releases the lease when Gun rejects an invalid request header", %{origin: origin} do
    adapter_opts = [
      tls_opts: [verify: :verify_none],
      connect_timeout: 2_000,
      timeout: 2_000
    ]

    client = Tesla.client([ConnectionPool], Tesla.Adapter.Gun)

    assert {:invalid_request_header, "x-test", _message} =
             catch_error(
               Tesla.get(client, origin.base_url <> "/final",
                 headers: [{"x-test", "value\r\nx-injected: true"}],
                 opts: [adapter: adapter_opts]
               )
             )

    assert worker_clients(origin.port) == %{}
    refute_receive {:origin_request, "/final"}
    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} = request(origin.base_url <> "/final")
  end

  test "requests through authenticated SOCKS5 with proxy-side DNS", %{
    origin: origin,
    socks_proxy: proxy
  } do
    proxy_opts = [
      proxy: {:socks5, ~c"127.0.0.1", proxy.port},
      proxy_auth: {"alice", "secret"}
    ]

    url = "https://localhost:#{origin.port}/final"
    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} = request(url, proxy_opts)

    assert_receive {:socks5_proxy, "alice", "secret", "localhost", origin_port}
    assert origin_port == origin.port
  end

  test "requests through unauthenticated SOCKS5 with an IP proxy host", %{
    origin: origin,
    socks_proxy: proxy
  } do
    proxy_opts = [proxy: {:socks5, {127, 0, 0, 1}, proxy.port}]

    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} =
             request(origin.base_url <> "/final", proxy_opts)

    assert_receive {:socks5_proxy, nil, nil, "127.0.0.1", origin_port}
    assert origin_port == origin.port
  end

  test "requests through unauthenticated SOCKS5 with a localhost proxy host", %{
    origin: origin,
    socks_proxy: proxy
  } do
    proxy_opts = [proxy: {:socks5, ~c"localhost", proxy.port}]

    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} =
             request(origin.base_url <> "/final", proxy_opts)

    assert_receive {:socks5_proxy, nil, nil, "127.0.0.1", origin_port}
    assert origin_port == origin.port
  end

  defp request(url, proxy_opts \\ [], follow_redirects \\ false) do
    middleware =
      if follow_redirects do
        [Tesla.Middleware.FollowRedirects, ConnectionPool]
      else
        [ConnectionPool]
      end

    adapter_opts =
      Keyword.merge(
        [tls_opts: [verify: :verify_none], connect_timeout: 2_000, timeout: 2_000],
        proxy_opts
      )

    middleware
    |> Tesla.client(Tesla.Adapter.Gun)
    |> Tesla.get(url, opts: [adapter: adapter_opts])
  end

  defp request_chunks(url, proxy_opts, follow_redirects \\ false) do
    adapter_opts =
      Keyword.merge(
        [
          body_as: :chunks,
          tls_opts: [verify: :verify_none],
          connect_timeout: 2_000,
          timeout: 2_000
        ],
        proxy_opts
      )

    middleware =
      if follow_redirects do
        [Tesla.Middleware.FollowRedirects, ConnectionPool]
      else
        [ConnectionPool]
      end

    middleware
    |> Tesla.client(Tesla.Adapter.Gun)
    |> Tesla.get(url, opts: [adapter: adapter_opts])
  end

  defp request_multipart(url, multipart, proxy_opts) do
    adapter_opts =
      Keyword.merge(
        [tls_opts: [verify: :verify_none], connect_timeout: 2_000, timeout: 2_000],
        proxy_opts
      )

    [ConnectionPool]
    |> Tesla.client(Tesla.Adapter.Gun)
    |> Tesla.post(url, multipart, opts: [adapter: adapter_opts])
  end

  defp request_stream(url, body, proxy_opts) do
    adapter_opts =
      Keyword.merge(
        [tls_opts: [verify: :verify_none], connect_timeout: 2_000, timeout: 2_000],
        proxy_opts
      )

    [ConnectionPool]
    |> Tesla.client(Tesla.Adapter.Gun)
    |> Tesla.post(url, body, opts: [adapter: adapter_opts])
  end

  defp collect_chunks(client, acc \\ "") do
    case Tesla.Adapter.Gun.read_chunk(client.pid, client.stream, client.opts) do
      {:nofin, chunk} -> collect_chunks(client, acc <> chunk)
      {:fin, chunk} -> acc <> chunk
    end
  end

  defp start_tls_origin(parent) do
    certfile = Path.expand("../../fixtures/server.pem", __DIR__)
    keyfile = Path.expand("../../fixtures/private_key.pem", __DIR__)

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        certfile: certfile,
        keyfile: keyfile,
        reuseaddr: true,
        active: false,
        packet: :raw,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :ssl.sockname(listener)
    {:ok, acceptor} = Task.start_link(fn -> accept_tls_loop(listener, parent) end)

    %{
      listener: listener,
      acceptor: acceptor,
      transport: :ssl,
      port: port,
      base_url: "https://127.0.0.1:#{port}"
    }
  end

  defp accept_tls_loop(listener, parent) do
    case :ssl.transport_accept(listener) do
      {:ok, tcp_socket} ->
        case :ssl.handshake(tcp_socket, 2_000) do
          {:ok, socket} ->
            pid = spawn(fn -> receive_and_serve_tls(socket, parent) end)
            :ok = :ssl.controlling_process(socket, pid)
            send(pid, :serve)

          {:error, _reason} ->
            :gen_tcp.close(tcp_socket)
        end

        accept_tls_loop(listener, parent)

      {:error, _reason} ->
        :ok
    end
  end

  defp receive_and_serve_tls(socket, parent) do
    receive do
      :serve -> serve_tls(socket, parent)
    end
  end

  defp serve_tls(socket, parent) do
    case recv_headers(:ssl, socket) do
      {:ok, request} ->
        {headers, buffered_body} = split_headers(request)
        path = request_path(headers)
        send(parent, {:origin_request, path})
        send(parent, {:origin_headers, path, headers})

        case path do
          "/redirect" ->
            send_tls_response(socket, 302, "Found", [{"Location", "/final"}], "")

          "/redirect_chunks" ->
            send_tls_response(socket, 302, "Found", [{"Location", "/chunks"}], "discard-me")

          "/final" ->
            send_tls_response(socket, 200, "OK", [], "ok")

          "/chunks" ->
            send_tls_chunks(socket, ["hel", "lo"])

          "/upload" ->
            {:ok, body} = recv_request_body(socket, headers, buffered_body)
            send(parent, {:origin_body, path, body})
            send_tls_response(socket, 200, "OK", [], "uploaded")

          _ ->
            send_tls_response(socket, 404, "Not Found", [], "not found")
        end

        serve_tls(socket, parent)

      {:error, _reason} ->
        :ssl.close(socket)
    end
  end

  defp send_tls_response(socket, status, reason, headers, body) do
    headers =
      [
        {"Content-Length", Integer.to_string(byte_size(body))},
        {"Connection", "keep-alive"}
      ] ++ headers

    :ssl.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason,
      "\r\n",
      Enum.map(headers, fn {key, value} -> [key, ": ", value, "\r\n"] end),
      "\r\n",
      body
    ])
  end

  defp send_tls_chunks(socket, chunks) do
    :ssl.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "Transfer-Encoding: chunked\r\n",
      "Connection: keep-alive\r\n\r\n",
      Enum.map(chunks, fn chunk ->
        [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"]
      end),
      "0\r\n\r\n"
    ])
  end

  defp start_connect_proxy(parent) do
    start_tcp_server(fn socket -> serve_connect_proxy(socket, parent) end)
  end

  defp serve_connect_proxy(socket, parent) do
    with {:ok, headers} <- recv_headers(:gen_tcp, socket),
         {:ok, host, port} <- parse_connect(headers),
         auth when is_binary(auth) <- header(headers, "proxy-authorization"),
         {:ok, upstream} <- tcp_connect(host, port) do
      send(parent, {:connect_proxy, auth, host, port})
      :ok = :gen_tcp.send(socket, "HTTP/1.1 200 Connection established\r\n\r\n")
      tunnel(socket, upstream)
    else
      _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n"
        )

        :gen_tcp.close(socket)
    end
  end

  defp start_forward_proxy(parent) do
    start_tcp_server(fn socket -> serve_forward_proxy(socket, parent) end)
  end

  defp serve_forward_proxy(socket, parent) do
    with {:ok, request} <- recv_headers(:gen_tcp, socket) do
      {headers, _buffered_body} = split_headers(request)
      target = request_path(headers)
      host = header(headers, "host")
      auth = header(headers, "proxy-authorization")

      if String.starts_with?(target, "http://") do
        send(parent, {:forward_proxy, target, host, auth})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok"
        )

        serve_forward_proxy(socket, parent)
      else
        :gen_tcp.send(
          socket,
          "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
      end
    end
  end

  defp start_socks5_proxy(parent) do
    start_tcp_server(fn socket -> serve_socks5_proxy(socket, parent) end)
  end

  defp serve_socks5_proxy(socket, parent) do
    with {:ok, <<5, method_count>>} <- :gen_tcp.recv(socket, 2, 2_000),
         {:ok, methods} <- :gen_tcp.recv(socket, method_count, 2_000),
         {:ok, username, password} <- negotiate_socks5_auth(socket, methods),
         {:ok, host, port} <- recv_socks5_destination(socket),
         {:ok, upstream} <- tcp_connect(host, port),
         :ok <- :gen_tcp.send(socket, <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>>) do
      send(parent, {:socks5_proxy, username, password, host, port})
      tunnel(socket, upstream)
    else
      _ ->
        :gen_tcp.close(socket)
    end
  end

  defp negotiate_socks5_auth(socket, methods) do
    cond do
      :binary.match(methods, <<2>>) != :nomatch ->
        with :ok <- :gen_tcp.send(socket, <<5, 2>>),
             {:ok, username, password} <- recv_socks5_auth(socket),
             :ok <- :gen_tcp.send(socket, <<1, 0>>) do
          {:ok, username, password}
        end

      :binary.match(methods, <<0>>) != :nomatch ->
        with :ok <- :gen_tcp.send(socket, <<5, 0>>) do
          {:ok, nil, nil}
        end

      true ->
        {:error, :unsupported_auth}
    end
  end

  defp recv_socks5_auth(socket) do
    with {:ok, <<1, username_length>>} <- :gen_tcp.recv(socket, 2, 2_000),
         {:ok, username} <- :gen_tcp.recv(socket, username_length, 2_000),
         {:ok, <<password_length>>} <- :gen_tcp.recv(socket, 1, 2_000),
         {:ok, password} <- :gen_tcp.recv(socket, password_length, 2_000) do
      {:ok, username, password}
    end
  end

  defp recv_socks5_destination(socket) do
    with {:ok, <<5, 1, 0, address_type>>} <- :gen_tcp.recv(socket, 4, 2_000),
         {:ok, host} <- recv_socks5_host(socket, address_type),
         {:ok, <<port::16>>} <- :gen_tcp.recv(socket, 2, 2_000) do
      {:ok, host, port}
    end
  end

  defp recv_socks5_host(socket, 1) do
    with {:ok, <<a, b, c, d>>} <- :gen_tcp.recv(socket, 4, 2_000) do
      {:ok, Enum.join([a, b, c, d], ".")}
    end
  end

  defp recv_socks5_host(socket, 3) do
    with {:ok, <<length>>} <- :gen_tcp.recv(socket, 1, 2_000),
         {:ok, host} <- :gen_tcp.recv(socket, length, 2_000) do
      {:ok, host}
    end
  end

  defp start_tcp_server(handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    {:ok, acceptor} = Task.start_link(fn -> accept_tcp_loop(listener, handler) end)
    %{listener: listener, acceptor: acceptor, transport: :gen_tcp, port: port}
  end

  defp accept_tcp_loop(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        pid = spawn(fn -> receive_and_serve_tcp(socket, handler) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :serve)
        accept_tcp_loop(listener, handler)

      {:error, _reason} ->
        :ok
    end
  end

  defp receive_and_serve_tcp(socket, handler) do
    receive do
      :serve -> handler.(socket)
    end
  end

  defp recv_headers(transport, socket, acc \\ <<>>) do
    case transport.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data

        if :binary.match(acc, "\r\n\r\n") == :nomatch do
          recv_headers(transport, socket, acc)
        else
          {:ok, acc}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp request_path(headers) do
    headers
    |> String.split("\r\n", parts: 2)
    |> hd()
    |> String.split(" ")
    |> Enum.at(1)
  end

  defp split_headers(request) do
    {index, 4} = :binary.match(request, "\r\n\r\n")
    split_at = index + 4
    <<headers::binary-size(split_at), body::binary>> = request
    {headers, body}
  end

  defp recv_request_body(socket, headers, buffered_body) do
    cond do
      String.contains?(String.downcase(headers), "transfer-encoding: chunked") ->
        recv_chunked_body(socket, buffered_body, "")

      content_length = header(headers, "content-length") ->
        recv_exact(socket, buffered_body, String.to_integer(content_length))

      true ->
        {:ok, buffered_body}
    end
  end

  defp recv_chunked_body(socket, buffer, acc) do
    with {:ok, line, buffer} <- recv_line(socket, buffer),
         {size, ""} <- Integer.parse(line, 16) do
      if size == 0 do
        {:ok, acc}
      else
        with {:ok, chunk_and_crlf, buffer} <- take_bytes(socket, buffer, size + 2),
             <<chunk::binary-size(size), "\r\n">> <- chunk_and_crlf do
          recv_chunked_body(socket, buffer, acc <> chunk)
        end
      end
    end
  end

  defp recv_line(socket, buffer) do
    case :binary.match(buffer, "\r\n") do
      {index, 2} ->
        <<line::binary-size(index), "\r\n", rest::binary>> = buffer
        {:ok, line, rest}

      :nomatch ->
        with {:ok, data} <- :ssl.recv(socket, 0, 2_000) do
          recv_line(socket, buffer <> data)
        end
    end
  end

  defp take_bytes(_socket, buffer, size) when byte_size(buffer) >= size do
    <<bytes::binary-size(size), rest::binary>> = buffer
    {:ok, bytes, rest}
  end

  defp take_bytes(socket, buffer, size) do
    with {:ok, data} <- :ssl.recv(socket, 0, 2_000) do
      take_bytes(socket, buffer <> data, size)
    end
  end

  defp recv_exact(socket, buffer, size) do
    with {:ok, body, _rest} <- take_bytes(socket, buffer, size) do
      {:ok, body}
    end
  end

  defp parse_connect(headers) do
    case headers |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ") do
      ["CONNECT", authority, _protocol] ->
        case String.split(authority, ":", parts: 2) do
          [host, port] -> {:ok, host, String.to_integer(port)}
          _ -> {:error, :invalid_authority}
        end

      _ ->
        {:error, :invalid_connect}
    end
  end

  defp header(headers, wanted_name) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == wanted_name, do: String.trim(value)

        _ ->
          nil
      end
    end)
  end

  defp tcp_connect(host, port) do
    :gen_tcp.connect(
      String.to_charlist(host),
      port,
      [:binary, active: false, packet: :raw],
      2_000
    )
  end

  defp worker_protocol(port) do
    case worker_state(port) do
      nil -> nil
      state -> state.protocol
    end
  end

  defp worker_clients(port) do
    case worker_state(port) do
      nil -> nil
      state -> state.clients
    end
  end

  defp worker_state(port) do
    prefix = "https:127.0.0.1:#{port}:"

    Pleroma.Gun.ConnectionPool
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.find_value(fn {key, worker} ->
      if String.starts_with?(key, prefix), do: :sys.get_state(worker)
    end)
  end

  defp tunnel(client, upstream) do
    :ok = :inet.setopts(client, active: :once)
    :ok = :inet.setopts(upstream, active: :once)
    tunnel_loop(client, upstream)
  end

  defp tunnel_loop(client, upstream) do
    receive do
      {:tcp, ^client, data} ->
        :ok = :gen_tcp.send(upstream, data)
        :ok = :inet.setopts(client, active: :once)
        tunnel_loop(client, upstream)

      {:tcp, ^upstream, data} ->
        :ok = :gen_tcp.send(client, data)
        :ok = :inet.setopts(upstream, active: :once)
        tunnel_loop(client, upstream)

      {:tcp_closed, _socket} ->
        :gen_tcp.close(client)
        :gen_tcp.close(upstream)

      {:tcp_error, _socket, _reason} ->
        :gen_tcp.close(client)
        :gen_tcp.close(upstream)
    after
      10_000 ->
        :gen_tcp.close(client)
        :gen_tcp.close(upstream)
    end
  end

  defp stop_server(%{listener: listener, acceptor: acceptor, transport: transport}) do
    transport.close(listener)

    if Process.alive?(acceptor), do: Process.exit(acceptor, :normal)
  end
end
