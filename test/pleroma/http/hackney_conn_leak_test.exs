# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# Regression guard for the Hackney dependency, not for Pleroma code.
#
# Hackney 4 leaks a `hackney_conn` gen_statem for an unpooled request that ends
# without a reusable socket: a body cut short by the peer, a bodyless 204/304,
# or a failed body read. `read_full_body/2` hands back `socket = undefined`, so
# the connection goes straight to its `closed` state, bypassing the reuse check;
# `closed(enter)` arms a stop timer only for pooled connections, and an unpooled
# one is owned by `hackney_conn_sup`, so the owner-DOWN cleanup never fires
# either. The process parks forever holding every refc binary it read.
#
# Pleroma cannot work around this: since 4.0 Hackney ignores `with_body` and
# always returns a fully read binary, so a synchronous request never yields a
# handle to close, and a truncated read still reports `{:ok, body}`.
#
# Media proxy warming hits this whenever an attachment fetch is cut short and
# the outbound proxy is used as a CONNECT tunnel, since tunnels are never
# pooled. That is how it was found.
#
# Fixed upstream by https://github.com/benoitc/hackney/pull/919; mix.exs pins
# that commit until it lands in a release. Should this start failing, the pin
# has been moved to a version without the fix.
#
# https://github.com/benoitc/hackney/issues/918
defmodule Pleroma.HTTP.HackneyConnLeakTest do
  use ExUnit.Case, async: false

  alias Pleroma.HTTP.AdapterHelper.Hackney, as: HackneyAdapterHelper

  @sent_bytes 64 * 1024
  @announced_bytes 100_000_000

  setup do
    {:ok, _} = Application.ensure_all_started(:hackney)

    {:ok, server} = start_server()
    on_exit(fn -> stop_server(server) end)

    {:ok, server: server}
  end

  test "an unpooled request with a truncated body does not leak a connection process", %{
    server: server
  } do
    before = conn_pids()

    # pool: false takes hackney's connect_direct/4 path, the same unpooled shape
    # a CONNECT tunnel gets. A pooled connection is reaped by the pool's own
    # grace timer and would not show the leak.
    assert {:ok, %Tesla.Env{status: 200, body: body}} =
             request(server, pool: false)

    # The short read still reports success, which is why nothing downstream
    # knows to clean up.
    assert byte_size(body) == @sent_bytes

    leaked = wait_for_cleanup(before)

    assert leaked == [],
           "leaked #{length(leaked)} hackney_conn process(es): " <>
             inspect(Enum.map(leaked, &describe/1))
  end

  # A control rather than a guard: a pooled connection is stopped by the pool's
  # own grace timer both before and after the fix. It is here to show the
  # unpooled assertion above is measuring the right thing.
  test "a pooled request with a truncated body does not leak either", %{server: server} do
    before = conn_pids()

    assert {:ok, %Tesla.Env{status: 200}} = request(server, pool: :media)

    assert wait_for_cleanup(before) == []
  end

  defp request(server, extra_opts) do
    url = "#{server.base_url}/truncated"

    adapter_opts =
      HackneyAdapterHelper.options([proxy: false] ++ extra_opts, URI.parse(url))

    client = Tesla.client([], Tesla.Adapter.Hackney)

    Tesla.request(client, method: :get, url: url, opts: [adapter: adapter_opts])
  end

  defp conn_pids do
    :hackney_conn_sup
    |> Process.whereis()
    |> case do
      nil ->
        []

      _ ->
        for {_, pid, _, _} <- :supervisor.which_children(:hackney_conn_sup), is_pid(pid), do: pid
    end
    |> MapSet.new()
  end

  # Only connections this test created matter; the pool may add unrelated ones.
  # A pooled connection gets a brief grace window before it stops, so poll
  # rather than sampling once.
  defp wait_for_cleanup(before, attempts \\ 40) do
    leaked =
      conn_pids()
      |> Enum.reject(&MapSet.member?(before, &1))
      |> Enum.filter(&Process.alive?/1)

    cond do
      leaked == [] -> []
      attempts == 0 -> leaked
      true -> Process.sleep(50) && wait_for_cleanup(before, attempts - 1)
    end
  end

  defp describe(pid) do
    state =
      try do
        pid |> :sys.get_state(200) |> elem(0)
      rescue
        _ -> :unknown
      catch
        :exit, _ -> :dead
      end

    binary =
      case Process.info(pid, :binary) do
        {:binary, refs} -> Enum.reduce(refs, 0, fn ref, acc -> acc + elem(ref, 1) end)
        _ -> 0
      end

    %{pid: pid, state: state, binary_bytes: binary}
  end

  # Announces a body far larger than it sends, then closes: what an upstream
  # aborting mid-stream looks like to the client.
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
    with {:ok, _data} <- recv_headers(socket) do
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: application/octet-stream\r\n",
        "Content-Length: #{@announced_bytes}\r\n\r\n",
        :binary.copy("x", @sent_bytes)
      ])
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
