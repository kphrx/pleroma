# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.HTTPSignaturePlugTest do
  use Pleroma.Web.ConnCase, async: true

  alias Pleroma.StaticStubbedConfigMock, as: ConfigMock
  alias Pleroma.StubbedHTTPSignaturesMock, as: HTTPSignaturesMock
  alias Pleroma.Web.Plugs.HTTPSignaturePlug

  import Mox
  import Phoenix.Controller, only: [put_format: 2]
  import Plug.Conn

  defp put_signature(conn, actor, signed_headers \\ "(request-target) host date") do
    conn
    |> put_req_header("date", Pleroma.Signature.signed_date())
    |> put_req_header(
      "signature",
      "keyId=\"#{actor}#main-key\",headers=\"#{signed_headers}\",signature=\"fake\""
    )
  end

  test "it calls HTTPSignatures to check validity if the actor signed it" do
    params = %{"actor" => "http://mastodon.example.org/users/admin"}
    conn = build_conn(:get, "/doesntmattter", params)

    HTTPSignaturesMock
    |> expect(:validate_conn, fn _ -> true end)

    conn =
      conn
      |> put_signature("http://mastodon.example.org/users/admin")
      |> put_format("activity+json")
      |> HTTPSignaturePlug.call(%{})

    assert conn.assigns.valid_signature == true
    assert conn.halted == false
  end

  describe "requires a signature when `authorized_fetch_mode` is enabled" do
    setup do
      params = %{"actor" => "http://mastodon.example.org/users/admin"}
      conn = build_conn(:get, "/doesntmattter", params) |> put_format("activity+json")

      [conn: conn]
    end

    test "when signature header is present", %{conn: orig_conn} do
      ConfigMock
      |> expect(:get, fn [:activitypub, :authorized_fetch_mode], false -> true end)
      |> expect(:get, fn [:activitypub, :authorized_fetch_mode_exceptions], [] -> [] end)

      HTTPSignaturesMock
      |> expect(:validate_conn, 2, fn _ -> false end)

      conn =
        orig_conn
        |> put_signature("http://mastodon.example.org/users/admin")
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == false
      assert conn.halted == true
      assert conn.status == 401
      assert conn.state == :sent
      assert conn.resp_body == "Request not signed"

      ConfigMock
      |> expect(:get, fn [:activitypub, :authorized_fetch_mode], false -> true end)

      HTTPSignaturesMock
      |> expect(:validate_conn, fn _ -> true end)

      conn =
        orig_conn
        |> put_signature("http://mastodon.example.org/users/admin")
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == true
      assert conn.halted == false
    end

    test "halts the connection when `signature` header is not present", %{conn: conn} do
      ConfigMock
      |> expect(:get, fn [:activitypub, :authorized_fetch_mode], false -> true end)
      |> expect(:get, fn [:activitypub, :authorized_fetch_mode_exceptions], [] -> [] end)

      conn = HTTPSignaturePlug.call(conn, %{})
      assert conn.assigns[:valid_signature] == nil
      assert conn.halted == true
      assert conn.status == 401
      assert conn.state == :sent
      assert conn.resp_body == "Request not signed"
    end

    test "exempts specific IPs from `authorized_fetch_mode_exceptions`", %{conn: conn} do
      ConfigMock
      |> expect(:get, fn [:activitypub, :authorized_fetch_mode], false -> true end)
      |> expect(:get, fn [:activitypub, :authorized_fetch_mode_exceptions], [] ->
        ["192.168.0.0/24"]
      end)
      |> expect(:get, fn [:activitypub, :authorized_fetch_mode], false -> true end)

      HTTPSignaturesMock
      |> expect(:validate_conn, 2, fn _ -> false end)

      conn =
        conn
        |> Map.put(:remote_ip, {192, 168, 0, 1})
        |> put_signature("http://mastodon.example.org/users/admin")
        |> HTTPSignaturePlug.call(%{})

      assert conn.remote_ip == {192, 168, 0, 1}
      assert conn.halted == false
    end
  end

  test "rejects requests from `rejected_instances` when `authorized_fetch_mode` is enabled" do
    ConfigMock
    |> expect(:get, fn [:activitypub, :authorized_fetch_mode], false -> true end)
    |> expect(:get, fn [:instance, :rejected_instances] ->
      [{"mastodon.example.org", "no reason"}]
    end)

    HTTPSignaturesMock
    |> expect(:validate_conn, fn _ -> true end)

    conn =
      build_conn(:get, "/doesntmattter", %{"actor" => "http://mastodon.example.org/users/admin"})
      |> put_signature("http://mastodon.example.org/users/admin")
      |> put_format("activity+json")
      |> HTTPSignaturePlug.call(%{})

    assert conn.assigns.valid_signature == true
    assert conn.halted == true

    ConfigMock
    |> expect(:get, fn [:activitypub, :authorized_fetch_mode], false -> true end)
    |> expect(:get, fn [:instance, :rejected_instances] ->
      [{"mastodon.example.org", "no reason"}]
    end)

    HTTPSignaturesMock
    |> expect(:validate_conn, fn _ -> true end)

    conn =
      build_conn(:get, "/doesntmattter", %{"actor" => "http://allowed.example.org/users/admin"})
      |> put_signature("http://allowed.example.org/users/admin")
      |> put_format("activity+json")
      |> HTTPSignaturePlug.call(%{})

    assert conn.assigns.valid_signature == true
    assert conn.halted == false
  end

  describe "signature policy" do
    test "treats a signed GET with a stale date as unsigned" do
      HTTPSignaturesMock
      |> expect(:validate_conn, 0, fn _ -> true end)

      stale = NaiveDateTime.add(NaiveDateTime.utc_now(), -3 * 3600)

      conn =
        build_conn(:get, "/doesntmattter")
        |> put_signature("http://mastodon.example.org/users/admin")
        |> put_req_header("date", Pleroma.Signature.signed_date(stale))
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == false
      assert conn.assigns.signature_error == :date_too_old
      refute conn.halted
    end

    test "marks a signed POST that does not cover the digest as invalid" do
      HTTPSignaturesMock
      |> expect(:validate_conn, 0, fn _ -> true end)

      conn =
        build_conn(:post, "/inbox")
        |> put_signature("http://mastodon.example.org/users/admin")
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == false
      assert conn.assigns.signature_error == :digest_not_signed
      refute conn.halted
    end

    test "uses the digest computed from the body for signed POSTs" do
      HTTPSignaturesMock
      |> expect(:validate_conn, fn conn ->
        get_req_header(conn, "digest") == ["SHA-256=computed"]
      end)

      conn =
        build_conn(:post, "/inbox")
        |> put_signature(
          "http://mastodon.example.org/users/admin",
          "(request-target) host date digest"
        )
        |> put_req_header("digest", "SHA-256=claimed")
        |> assign(:digest, "SHA-256=computed")
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == true
    end

    test "marks a signed POST whose body was not hashed as invalid" do
      HTTPSignaturesMock
      |> expect(:validate_conn, 0, fn _ -> true end)

      conn =
        build_conn(:post, "/inbox")
        |> put_signature(
          "http://mastodon.example.org/users/admin",
          "(request-target) host date digest"
        )
        |> put_req_header("digest", "SHA-256=claimed")
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == false
      assert conn.assigns.signature_error == :body_not_hashed
    end
  end
end
