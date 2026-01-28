# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.HackneyFollowRedirectRegressionTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _} = Application.ensure_all_started(:hackney)

    {:ok, tls_server} = start_tls_redirect_server()
    {:ok, proxy} = start_connect_proxy()

    on_exit(fn ->
      stop_connect_proxy(proxy)
      stop_tls_redirect_server(tls_server)
    end)

    {:ok, tls_server: tls_server, proxy: proxy}
  end

  test "hackney follow_redirect crashes behind CONNECT proxy on relative redirects", %{
    tls_server: tls_server,
    proxy: proxy
  } do
    url = "#{tls_server.base_url}/redirect"

    opts = [
      pool: :media,
      proxy: proxy.proxy_url,
      insecure: true,
      connect_timeout: 1_000,
      recv_timeout: 1_000,
      follow_redirect: true,
      force_redirect: true
    ]

    {pid, ref} = spawn_monitor(fn -> :hackney.request(:get, url, [], <<>>, opts) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000

    assert match?({%FunctionClauseError{}, _}, reason) or match?(%FunctionClauseError{}, reason) or
             match?({:function_clause, _}, reason)
  end

  test "redirects work via proxy when hackney follow_redirect is disabled", %{
    tls_server: tls_server,
    proxy: proxy
  } do
    url = "#{tls_server.base_url}/redirect"

    adapter_opts = [
      pool: :media,
      proxy: proxy.proxy_url,
      insecure: true,
      connect_timeout: 1_000,
      recv_timeout: 1_000,
      follow_redirect: false,
      force_redirect: false,
      with_body: true
    ]

    client = Tesla.client([Tesla.Middleware.FollowRedirects], Tesla.Adapter.Hackney)

    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} =
             Tesla.request(client, method: :get, url: url, opts: [adapter: adapter_opts])
  end

  test "reverse proxy hackney client follows redirects via proxy without crashing", %{
    tls_server: tls_server,
    proxy: proxy
  } do
    url = "#{tls_server.base_url}/redirect"

    opts = [
      pool: :media,
      proxy: proxy.proxy_url,
      insecure: true,
      connect_timeout: 1_000,
      recv_timeout: 1_000,
      follow_redirect: true
    ]

    assert {:ok, 200, _headers, ref} =
             Pleroma.ReverseProxy.Client.Hackney.request(:get, url, [], "", opts)

    assert collect_body(ref) == "ok"
    Pleroma.ReverseProxy.Client.Hackney.close(ref)
  end

  test "hackney reverse proxy follows nested redirects via proxy", %{
    tls_server: tls_server,
    proxy: proxy
  } do
    url = "#{tls_server.base_url}/nested_redirect"

    opts = [
      pool: :media,
      proxy: proxy.proxy_url,
      insecure: true,
      connect_timeout: 1_000,
      recv_timeout: 1_000,
      follow_redirect: true
    ]

    assert {:ok, 200, _headers, ref} =
             Pleroma.ReverseProxy.Client.Hackney.request(:get, url, [], "", opts)

    assert collect_body(ref) == "ok"
    Pleroma.ReverseProxy.Client.Hackney.close(ref)
  end

  test "hackney reverse proxy stops following redirects after limit is reached", %{
    tls_server: tls_server,
    proxy: proxy
  } do
    url = "#{tls_server.base_url}/infinite_redirect"

    opts = [
      pool: :media,
      proxy: proxy.proxy_url,
      insecure: true,
      connect_timeout: 1_000,
      recv_timeout: 1_000,
      follow_redirect: true
    ]

    assert {:ok, 302, _headers, ref} =
             Pleroma.ReverseProxy.Client.Hackney.request(:get, url, [], "", opts)

    Pleroma.ReverseProxy.Client.Hackney.close(ref)
  end

  defp collect_body(ref, acc \\ "") do
    case Pleroma.ReverseProxy.Client.Hackney.stream_body(ref) do
      :done -> acc
      {:ok, data, _ref} -> collect_body(ref, acc <> data)
      {:error, error} -> flunk("stream_body failed: #{inspect(error)}")
    end
  end

  defp start_tls_redirect_server do
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

    {:ok, acceptor} =
      Task.start_link(fn ->
        accept_tls_loop(listener)
      end)

    {:ok, %{listener: listener, acceptor: acceptor, base_url: "https://127.0.0.1:#{port}"}}
  end

  defp stop_tls_redirect_server(%{listener: listener, acceptor: acceptor}) do
    :ok = :ssl.close(listener)

    if Process.alive?(acceptor) do
      Process.exit(acceptor, :normal)
    end
  end

  defp accept_tls_loop(listener) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        _ = Task.start(fn -> serve_tls(socket) end)
        accept_tls_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_tls(tcp_socket) do
    with {:ok, ssl_socket} <- :ssl.handshake(tcp_socket, 2_000),
         {:ok, data} <- recv_ssl_headers(ssl_socket),
         {:ok, path} <- parse_path(data) do
      case path do
        "/infinite_redirect" ->
          send_ssl_response(ssl_socket, 302, "Found", [{"Location", "/infinite_redirect"}], "")

        "/nested_redirect" ->
          send_ssl_response(ssl_socket, 302, "Found", [{"Location", "/redirect"}], "")

        "/redirect" ->
          send_ssl_response(ssl_socket, 302, "Found", [{"Location", "/final"}], "")

        "/final" ->
          send_ssl_response(ssl_socket, 200, "OK", [], "ok")

        _ ->
          send_ssl_response(ssl_socket, 404, "Not Found", [], "not found")
      end

      :ssl.close(ssl_socket)
    else
      _ ->
        _ = :gen_tcp.close(tcp_socket)
        :ok
    end
  end

  defp recv_ssl_headers(socket, acc \\ <<>>) do
    case :ssl.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data

        if :binary.match(acc, "\r\n\r\n") != :nomatch do
          {:ok, acc}
        else
          if byte_size(acc) > 8_192 do
            {:error, :too_large}
          else
            recv_ssl_headers(socket, acc)
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp send_ssl_response(socket, status, reason, headers, body) do
    base_headers =
      [
        {"Content-Length", Integer.to_string(byte_size(body))},
        {"Connection", "close"}
      ] ++ headers

    iodata =
      [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " ",
        reason,
        "\r\n",
        Enum.map(base_headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
        "\r\n",
        body
      ]

    :ssl.send(socket, iodata)
  end

  defp start_connect_proxy do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    {:ok, acceptor} =
      Task.start_link(fn ->
        accept_proxy_loop(listener)
      end)

    {:ok, %{listener: listener, acceptor: acceptor, proxy_url: "127.0.0.1:#{port}"}}
  end

  defp stop_connect_proxy(%{listener: listener, acceptor: acceptor}) do
    :ok = :gen_tcp.close(listener)

    if Process.alive?(acceptor) do
      Process.exit(acceptor, :normal)
    end
  end

  defp accept_proxy_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _ = Task.start(fn -> serve_proxy(socket) end)
        accept_proxy_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_proxy(client_socket) do
    with {:ok, {headers, rest}} <- recv_tcp_headers(client_socket),
         {:ok, {host, port}} <- parse_connect(headers),
         {:ok, upstream_socket} <- connect_upstream(host, port) do
      :gen_tcp.send(client_socket, "HTTP/1.1 200 Connection established\r\n\r\n")

      if rest != <<>> do
        :gen_tcp.send(upstream_socket, rest)
      end

      tunnel(client_socket, upstream_socket)
    else
      _ ->
        :gen_tcp.close(client_socket)
        :ok
    end
  end

  defp tunnel(client_socket, upstream_socket) do
    parent = self()
    _ = spawn_link(fn -> forward(client_socket, upstream_socket, parent) end)
    _ = spawn_link(fn -> forward(upstream_socket, client_socket, parent) end)

    receive do
      :tunnel_closed -> :ok
    after
      10_000 -> :ok
    end

    :gen_tcp.close(client_socket)
    :gen_tcp.close(upstream_socket)
  end

  defp forward(from_socket, to_socket, parent) do
    case :gen_tcp.recv(from_socket, 0, 10_000) do
      {:ok, data} ->
        _ = :gen_tcp.send(to_socket, data)
        forward(from_socket, to_socket, parent)

      {:error, _reason} ->
        send(parent, :tunnel_closed)
        :ok
    end
  end

  defp recv_tcp_headers(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data

        case :binary.match(acc, "\r\n\r\n") do
          :nomatch ->
            if byte_size(acc) > 8_192 do
              {:error, :too_large}
            else
              recv_tcp_headers(socket, acc)
            end

          {idx, _len} ->
            split_at = idx + 4
            <<headers::binary-size(split_at), rest::binary>> = acc
            {:ok, {headers, rest}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_connect(data) do
    with [request_line | _] <- String.split(data, "\r\n", trim: true),
         ["CONNECT", hostport | _] <- String.split(request_line, " ", parts: 3),
         [host, port_str] <- String.split(hostport, ":", parts: 2),
         {port, ""} <- Integer.parse(port_str) do
      {:ok, {host, port}}
    else
      _ -> {:error, :invalid_connect}
    end
  end

  defp connect_upstream(host, port) do
    address =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} -> ip
        {:error, _} -> String.to_charlist(host)
      end

    :gen_tcp.connect(address, port, [:binary, active: false, packet: :raw], 1_000)
  end

  defp parse_path(data) do
    case String.split(data, "\r\n", parts: 2) do
      [request_line | _] ->
        case String.split(request_line, " ") do
          [_method, path, _protocol] -> {:ok, path}
          _ -> {:error, :invalid_request}
        end

      _ ->
        {:error, :invalid_request}
    end
  end
end
