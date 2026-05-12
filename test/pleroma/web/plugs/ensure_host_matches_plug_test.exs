# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.EnsureHostMatchesPlugTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.Plugs.EnsureHostMatchesPlug

  import Mock
  import Plug.Conn
  import Tesla.Mock

  setup do
    mock(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  defp set_host(conn, host), do: %{conn | req_headers: conn.req_headers ++ [{"host", host}]}

  describe "EnsureHostMatchesPlug" do
    setup do
      conn = build_conn(:post, "/cofe") |> assign(:valid_signature, true)
      [conn: conn]
    end

    test "gracefully handles no Host header", %{conn: conn} do
      conn = EnsureHostMatchesPlug.call(conn, %{})

      assert conn.status == 400
      assert conn.halted == true
      assert conn.resp_body == "Host header not provided"
    end

    test "gracefully handles empty Host header", %{conn: conn} do
      conn =
        conn
        |> set_host("")
        |> EnsureHostMatchesPlug.call(%{})

      assert conn.status == 400
      assert conn.halted == true
      assert conn.resp_body == "Host header not provided"
    end

    test "it rejects Host header not matching Endpoint URL", %{conn: conn} do
      conn =
        conn
        |> set_host("invalid.example.com")
        |> EnsureHostMatchesPlug.call(%{})

      assert conn.status == 400
      assert conn.halted == true
      assert conn.resp_body == "Host header does not match this instance"
    end

    test "it rejects Host header not matching Endpoint with port", %{conn: conn} do
      endpoint = URI.parse(Endpoint.url())

      conn =
        conn
        |> set_host("invalid.example.com:#{endpoint.port}")
        |> EnsureHostMatchesPlug.call(%{})

      assert conn.status == 400
      assert conn.halted == true
      assert conn.resp_body == "Host header does not match this instance"
    end

    test "it rejects Host header not matching Endpoint port", %{conn: conn} do
      endpoint = URI.parse(Endpoint.url())

      conn =
        conn
        |> set_host("#{endpoint.host}:25")
        |> EnsureHostMatchesPlug.call(%{})

      assert conn.status == 400
      assert conn.halted == true
      assert conn.resp_body == "Host header does not match this instance"
    end

    test "it rejects multiple Host headers", %{conn: conn} do
      conn =
        conn
        |> set_host("host1.example.com")
        |> set_host("host2.example.com")
        |> EnsureHostMatchesPlug.call(%{})

      assert conn.status == 400
      assert conn.halted == true
      assert conn.resp_body == "More than one Host header provided"
    end

    test "it works for Host header without port", %{conn: conn} do
      endpoint = URI.parse(Endpoint.url())

      conn =
        conn
        |> set_host("#{endpoint.host}")
        |> EnsureHostMatchesPlug.call(%{})

      assert conn.halted == false
      assert Map.get(conn.assigns, :valid_host_header, nil)
    end

    test "it works for Host header with port as 80", %{conn: conn} do
      endpoint = URI.parse(Endpoint.url())

      conn =
        conn
        |> set_host("#{endpoint.host}:80")
        |> EnsureHostMatchesPlug.call(%{})

      assert conn.halted == false
      assert Map.get(conn.assigns, :valid_host_header, nil)
    end

    test "it works for Host header with port as 443", %{conn: conn} do
      with_mock Pleroma.Web.Endpoint, url: fn -> "https://localhost:4001" end do
        endpoint = URI.parse(Endpoint.url())

        conn =
          conn
          |> set_host("#{endpoint.host}:443")
          |> EnsureHostMatchesPlug.call(%{})

        assert conn.halted == false
        assert Map.get(conn.assigns, :valid_host_header, nil)
      end
    end

    test "it works for Host header with port as same as Endpoint (no reverse proxy config)", %{
      conn: conn
    } do
      endpoint = URI.parse(Endpoint.url())

      conn =
        conn
        |> set_host("#{endpoint.host}:#{endpoint.port}")
        |> EnsureHostMatchesPlug.call(%{})

      assert conn.halted == false
      assert Map.get(conn.assigns, :valid_host_header, nil)
    end
  end
end
