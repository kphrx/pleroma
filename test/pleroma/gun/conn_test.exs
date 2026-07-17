# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun.ConnTest do
  use ExUnit.Case

  import Mox

  alias Pleroma.Gun.Conn

  setup :verify_on_exit!

  setup do
    stub(Pleroma.GunMock, :await_up, fn _, _ -> {:ok, :http} end)
    stub(Pleroma.GunMock, :await_tunnel_up, fn _, _, _ -> {:ok, :http2} end)
    stub(Pleroma.GunMock, :close, fn _ -> :ok end)

    :ok
  end

  test "selects the direct transport from the URI scheme" do
    expect(Pleroma.GunMock, :open, 2, fn
      ~c"example.com", 8443, %{transport: :tls, tls_opts: tls_opts} ->
        assert tls_opts[:verify] == :verify_peer
        {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}

      ~c"example.com", 443, %{transport: :tcp} ->
        {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
    end)

    assert {:ok, https_conn, :http, nil} = Conn.open(URI.parse("https://example.com:8443"), [])
    assert {:ok, http_conn, :http, nil} = Conn.open(URI.parse("http://example.com:443"), [])

    stop_conn(https_conn)
    stop_conn(http_conn)
  end

  test "passes authentication to an HTTP CONNECT proxy" do
    conn = spawn_link(fn -> Process.sleep(:infinity) end)
    stream = make_ref()

    expect(Pleroma.GunMock, :open, fn ~c"proxy.example", 8080, opts ->
      assert opts.transport == :tcp
      refute Map.has_key?(opts, :tls_opts)
      {:ok, conn}
    end)

    expect(Pleroma.GunMock, :connect, fn ^conn, connect_opts ->
      assert connect_opts.username == "alice"
      assert connect_opts.password == "secret"
      assert connect_opts.transport == :tls
      assert connect_opts.protocols == [:http2, :http]
      stream
    end)

    expect(Pleroma.GunMock, :await, fn ^conn, ^stream -> {:response, :fin, 200, []} end)

    assert {:ok, ^conn, :http2, ^stream} =
             Conn.open(URI.parse("https://origin.example/inbox"),
               proxy: {~c"proxy.example", 8080},
               proxy_auth: {"alice", "secret"}
             )

    stop_conn(conn)
  end

  test "uses separate TLS options for a TLS CONNECT proxy" do
    conn = spawn_link(fn -> Process.sleep(:infinity) end)
    stream = make_ref()

    expect(Pleroma.GunMock, :open, fn ~c"proxy.example", 8443, opts ->
      assert opts.transport == :tls
      assert opts.tls_opts == [verify: :verify_none]
      {:ok, conn}
    end)

    expect(Pleroma.GunMock, :connect, fn ^conn, _connect_opts -> stream end)
    expect(Pleroma.GunMock, :await, fn ^conn, ^stream -> {:response, :fin, 200, []} end)

    assert {:ok, ^conn, :http2, ^stream} =
             Conn.open(URI.parse("https://origin.example/inbox"),
               proxy: {~c"proxy.example", 8443},
               transport: :tls,
               proxy_tls_opts: [verify: :verify_none]
             )

    stop_conn(conn)
  end

  test "passes authentication and remote DNS destination to a SOCKS5 proxy" do
    conn = spawn_link(fn -> Process.sleep(:infinity) end)

    expect(Pleroma.GunMock, :open, fn ~c"proxy.example", 1080, opts ->
      assert opts.protocols == [:socks]
      assert opts.transport == :tcp
      assert opts.socks_opts.host == ~c"origin.example"
      assert opts.socks_opts.port == 443
      assert opts.socks_opts.auth == [{:username_password, "alice", "secret"}]
      assert opts.socks_opts.transport == :tls
      assert opts.socks_opts.protocols == [:http2, :http]
      refute Map.has_key?(opts, :tls_opts)
      {:ok, conn}
    end)

    stub(Pleroma.GunMock, :await_up, fn _, _ -> {:ok, :socks} end)

    assert {:ok, ^conn, :http2, nil} =
             Conn.open(URI.parse("https://origin.example/inbox"),
               proxy: {:socks5, ~c"proxy.example", 1080},
               proxy_auth: {"alice", "secret"}
             )

    stop_conn(conn)
  end

  test "closes a CONNECT socket when proxy authentication fails" do
    conn = spawn_link(fn -> Process.sleep(:infinity) end)
    stream = make_ref()

    expect(Pleroma.GunMock, :open, fn _, _, _ -> {:ok, conn} end)
    expect(Pleroma.GunMock, :connect, fn ^conn, _ -> stream end)
    expect(Pleroma.GunMock, :await, fn ^conn, ^stream -> {:response, :nofin, 407, []} end)
    expect(Pleroma.GunMock, :close, fn ^conn -> Process.exit(conn, :normal) end)

    assert {:error, :proxy_auth_failed} =
             Conn.open(URI.parse("https://origin.example/inbox"),
               proxy: {~c"proxy.example", 8080},
               proxy_auth: {"alice", "wrong"}
             )
  end

  test "rejects SOCKS4 before opening a socket" do
    assert {:error, :socks4_unsupported} =
             Conn.open(URI.parse("https://origin.example/inbox"),
               proxy: {:socks4, ~c"proxy.example", 1080}
             )
  end

  defp stop_conn(conn) do
    Process.unlink(conn)
    Process.exit(conn, :kill)
  end
end
