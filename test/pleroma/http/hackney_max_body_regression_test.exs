# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# Hackney 4 ignores `with_body` and always returns a fully read binary, so
# `Tesla.Adapter.Hackney` never reaches the clause that honours `:max_body`.
# The limit is enforced by Pleroma.Tesla.Middleware.MaxBody instead; these
# exercise it against the real adapter.
defmodule Pleroma.HTTP.HackneyMaxBodyRegressionTest do
  use ExUnit.Case, async: false

  alias Pleroma.HTTP.AdapterHelper.Hackney, as: HackneyAdapterHelper

  @body_bytes 64 * 1024

  setup do
    {:ok, _} = Application.ensure_all_started(:hackney)

    {:ok, server} = start_server()
    on_exit(fn -> stop_server(server) end)

    {:ok, server: server}
  end

  defp request(url, extra_opts) do
    adapter_opts =
      HackneyAdapterHelper.options(
        [pool: :media, proxy: false] ++ extra_opts,
        URI.parse(url)
      )

    client =
      Tesla.client(
        [Tesla.Middleware.FollowRedirects, Pleroma.Tesla.Middleware.MaxBody],
        Tesla.Adapter.Hackney
      )

    Tesla.request(client, method: :get, url: url, opts: [adapter: adapter_opts])
  end

  test "a body over max_body is refused", %{server: server} do
    assert {:error, :body_too_large} =
             request("#{server.base_url}/big", max_body: 1024)
  end

  # Without a Content-Length the header pre-check cannot fire, so this is the
  # case that proves hackney's fully-read binary is measured.
  test "a chunked body over max_body is refused on size alone", %{server: server} do
    assert {:error, :body_too_large} =
             request("#{server.base_url}/chunked", max_body: 1024)
  end

  test "a body under max_body is returned", %{server: server} do
    assert {:ok, %Tesla.Env{status: 200, body: body}} =
             request("#{server.base_url}/big", max_body: @body_bytes * 2)

    assert byte_size(body) == @body_bytes
  end

  test "without max_body the body is returned whatever its size", %{server: server} do
    assert {:ok, %Tesla.Env{status: 200, body: body}} = request("#{server.base_url}/big", [])
    assert byte_size(body) == @body_bytes
  end

  # Pins why the middleware is needed. Tesla.Adapter.Hackney only honours
  # :max_body on the branch where hackney hands back a ref, which 4.x never
  # does for a synchronous request. Should this ever start failing, hackney or
  # Tesla have regained streaming and the middleware can go.
  test "the bare adapter does not enforce max_body", %{server: server} do
    url = "#{server.base_url}/big"

    adapter_opts =
      HackneyAdapterHelper.options(
        [pool: :media, proxy: false, max_body: 1024],
        URI.parse(url)
      )

    client = Tesla.client([], Tesla.Adapter.Hackney)

    assert {:ok, %Tesla.Env{status: 200, body: body}} =
             Tesla.request(client, method: :get, url: url, opts: [adapter: adapter_opts])

    assert byte_size(body) == @body_bytes
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
    {:ok, acceptor} = Task.start(fn -> accept_loop(listener) end)

    {:ok, %{listener: listener, acceptor: acceptor, base_url: "http://127.0.0.1:#{port}"}}
  end

  # Closing the listener makes the blocked accept/1 return {:error, :closed},
  # which ends the loop.
  defp stop_server(%{listener: listener, acceptor: acceptor}) do
    :ok = :gen_tcp.close(listener)
    if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket)
        accept_loop(listener)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket) do
    with {:ok, data} <- recv_headers(socket) do
      body = :binary.copy("x", @body_bytes)

      if String.contains?(data, "/chunked") do
        # No Content-Length, so only the body-size check can catch this.
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\n",
          "Content-Type: text/plain\r\n",
          "Transfer-Encoding: chunked\r\n",
          "Connection: close\r\n\r\n",
          :erlang.integer_to_list(byte_size(body), 16),
          "\r\n",
          body,
          "\r\n0\r\n\r\n"
        ])
      else
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\n",
          "Content-Type: text/plain\r\n",
          "Content-Length: #{byte_size(body)}\r\n",
          "Connection: close\r\n\r\n",
          body
        ])
      end
    end

    :gen_tcp.close(socket)
  end

  defp recv_headers(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data

        cond do
          :binary.match(acc, "\r\n\r\n") != :nomatch -> {:ok, acc}
          byte_size(acc) > 8_192 -> {:error, :too_large}
          true -> recv_headers(socket, acc)
        end

      {:error, _} = error ->
        error
    end
  end
end
