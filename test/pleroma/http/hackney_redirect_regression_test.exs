# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.HackneyRedirectRegressionTest do
  use ExUnit.Case, async: false

  alias Pleroma.HTTP.AdapterHelper.Hackney, as: HackneyAdapterHelper

  setup do
    {:ok, _} = Application.ensure_all_started(:hackney)

    {:ok, server} = start_server()
    on_exit(fn -> stop_server(server) end)

    {:ok, server: server}
  end

  test "pooled redirects work with follow_redirect disabled", %{server: server} do
    url = "#{server.base_url}/redirect"
    uri = URI.parse(url)

    adapter_opts =
      HackneyAdapterHelper.options(
        [pool: :media, follow_redirect: false, no_proxy_env: true],
        uri
      )

    client = Tesla.client([Tesla.Middleware.FollowRedirects], Tesla.Adapter.Hackney)

    assert {:ok, %Tesla.Env{status: 200, body: "ok"}} =
             Tesla.request(client, method: :get, url: url, opts: [adapter: adapter_opts])
  end

  defp start_server do
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
        accept_loop(listener)
      end)

    {:ok, %{listener: listener, acceptor: acceptor, base_url: "http://127.0.0.1:#{port}"}}
  end

  defp stop_server(%{listener: listener, acceptor: acceptor}) do
    :ok = :gen_tcp.close(listener)

    if Process.alive?(acceptor) do
      Process.exit(acceptor, :normal)
    end
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket)
        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket) do
    with {:ok, data} <- recv_headers(socket),
         {:ok, path} <- parse_path(data) do
      case path do
        "/redirect" ->
          send_response(socket, 302, "Found", [{"Location", "/final"}], "")

        "/final" ->
          send_response(socket, 200, "OK", [], "ok")

        _ ->
          send_response(socket, 404, "Not Found", [], "not found")
      end
    else
      _ -> :ok
    end

    :gen_tcp.close(socket)
  end

  defp recv_headers(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data

        if :binary.match(acc, "\r\n\r\n") != :nomatch do
          {:ok, acc}
        else
          if byte_size(acc) > 8_192 do
            {:error, :too_large}
          else
            recv_headers(socket, acc)
          end
        end

      {:error, _} = error ->
        error
    end
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

  defp send_response(socket, status, reason, headers, body) do
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

    :gen_tcp.send(socket, iodata)
  end
end
