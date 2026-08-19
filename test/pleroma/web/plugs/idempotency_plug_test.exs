# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.IdempotencyPlugTest do
  # Relies on Cachex, has to stay synchronous
  use Pleroma.DataCase
  import Plug.Conn
  import Plug.Test

  alias Pleroma.Web.Plugs.IdempotencyPlug
  alias Plug.Conn

  test "returns result from cache" do
    key = "test1"
    orig_request_id = "test1"
    second_request_id = "test2"
    body = "testing"
    status = 200

    :post
    |> conn("/cofe")
    |> put_req_header("idempotency-key", key)
    |> Conn.put_resp_header("x-request-id", orig_request_id)
    |> Conn.put_resp_content_type("application/json")
    |> IdempotencyPlug.call([])
    |> Conn.send_resp(status, body)

    conn =
      :post
      |> conn("/cofe")
      |> put_req_header("idempotency-key", key)
      |> Conn.put_resp_header("x-request-id", second_request_id)
      |> Conn.put_resp_content_type("application/json")
      |> IdempotencyPlug.call([])

    assert_raise Conn.AlreadySentError, fn ->
      Conn.send_resp(conn, :im_a_teapot, "no cofe")
    end

    assert conn.resp_body == body
    assert conn.status == status

    assert [^second_request_id] = Conn.get_resp_header(conn, "x-request-id")
    assert [^orig_request_id] = Conn.get_resp_header(conn, "x-original-request-id")
    assert [^key] = Conn.get_resp_header(conn, "idempotency-key")
    assert ["true"] = Conn.get_resp_header(conn, "idempotent-replayed")
    assert ["application/json; charset=utf-8"] = Conn.get_resp_header(conn, "content-type")
  end

  test "pass conn downstream if the cache not found" do
    key = "test2"
    orig_request_id = "test3"
    body = "testing"
    status = 200

    conn =
      :post
      |> conn("/cofe")
      |> put_req_header("idempotency-key", key)
      |> Conn.put_resp_header("x-request-id", orig_request_id)
      |> Conn.put_resp_content_type("application/json")
      |> IdempotencyPlug.call([])
      |> Conn.send_resp(status, body)

    assert conn.resp_body == body
    assert conn.status == status

    assert [] = Conn.get_resp_header(conn, "idempotent-replayed")
    assert [^key] = Conn.get_resp_header(conn, "idempotency-key")
  end

  test "does not cache responses marked as sensitive" do
    key = Ecto.UUID.generate()

    :post
    |> conn("/cofe")
    |> put_req_header("idempotency-key", key)
    |> Conn.put_resp_header("x-request-id", "sensitive-request")
    |> Conn.put_resp_content_type("application/json")
    |> IdempotencyPlug.call([])
    |> Conn.put_private(:skip_idempotency_cache, true)
    |> Conn.send_resp(200, "secret")

    conn =
      :post
      |> conn("/cofe")
      |> put_req_header("idempotency-key", key)
      |> Conn.put_resp_header("x-request-id", "second-request")
      |> Conn.put_resp_content_type("application/json")
      |> IdempotencyPlug.call([])

    refute conn.halted
    refute conn.resp_body
  end

  test "does not replay legacy unscoped cache entries" do
    key = Ecto.UUID.generate()
    record = {"legacy-request", "application/json", 200, "secret"}
    assert {:ok, true} = Cachex.put(:idempotency_cache, key, record)

    conn =
      :post
      |> conn("/cofe")
      |> put_req_header("idempotency-key", key)
      |> Conn.put_resp_header("x-request-id", "new-request")
      |> Conn.put_resp_content_type("application/json")
      |> IdempotencyPlug.call([])

    refute conn.halted
    refute conn.resp_body
  end

  test "scopes cached responses to the route and authenticated actor" do
    key = Ecto.UUID.generate()

    :post
    |> conn("/cofe")
    |> Conn.assign(:user, %{id: "user-one", is_admin: false, is_moderator: false})
    |> put_req_header("idempotency-key", key)
    |> Conn.put_resp_header("x-request-id", "original-request")
    |> Conn.put_resp_content_type("application/json")
    |> IdempotencyPlug.call([])
    |> Conn.send_resp(200, "one")

    for {path, user} <- [
          {"/tea", %{id: "user-one", is_admin: false, is_moderator: false}},
          {"/cofe", %{id: "user-two", is_admin: false, is_moderator: false}},
          {"/cofe", %{id: "user-one", is_admin: true, is_moderator: false}}
        ] do
      conn =
        :post
        |> conn(path)
        |> Conn.assign(:user, user)
        |> put_req_header("idempotency-key", key)
        |> Conn.put_resp_header("x-request-id", Ecto.UUID.generate())
        |> Conn.put_resp_content_type("application/json")
        |> IdempotencyPlug.call([])

      refute conn.halted
      refute conn.resp_body
    end
  end

  test "scopes cached responses to the OAuth application and token" do
    key = Ecto.UUID.generate()

    :post
    |> conn("/cofe")
    |> Conn.assign(:app, %{id: "app-one"})
    |> Conn.assign(:token, %{id: "token-one", scopes: ["write"]})
    |> put_req_header("idempotency-key", key)
    |> Conn.put_resp_header("x-request-id", "original-request")
    |> Conn.put_resp_content_type("application/json")
    |> IdempotencyPlug.call([])
    |> Conn.send_resp(200, "one")

    for {app, token} <- [
          {%{id: "app-two"}, %{id: "token-two", scopes: ["write"]}},
          {%{id: "app-one"}, %{id: "token-two", scopes: ["write"]}},
          {%{id: "app-one"}, %{id: "token-one", scopes: ["read"]}}
        ] do
      conn =
        :post
        |> conn("/cofe")
        |> Conn.assign(:app, app)
        |> Conn.assign(:token, token)
        |> put_req_header("idempotency-key", key)
        |> Conn.put_resp_header("x-request-id", Ecto.UUID.generate())
        |> Conn.put_resp_content_type("application/json")
        |> IdempotencyPlug.call([])

      refute conn.halted
      refute conn.resp_body
    end
  end

  test "scopes cached responses to configured staff privileges" do
    key = Ecto.UUID.generate()
    clear_config([:instance, :admin_privileges], [:users_delete])

    :post
    |> conn("/cofe")
    |> Conn.assign(:user, %{id: "admin", is_admin: true, is_moderator: false})
    |> put_req_header("idempotency-key", key)
    |> Conn.put_resp_header("x-request-id", "original-request")
    |> Conn.put_resp_content_type("application/json")
    |> IdempotencyPlug.call([])
    |> Conn.send_resp(200, "one")

    clear_config([:instance, :admin_privileges], [])

    conn =
      :post
      |> conn("/cofe")
      |> Conn.assign(:user, %{id: "admin", is_admin: true, is_moderator: false})
      |> put_req_header("idempotency-key", key)
      |> Conn.put_resp_header("x-request-id", "second-request")
      |> Conn.put_resp_content_type("application/json")
      |> IdempotencyPlug.call([])

    refute conn.halted
    refute conn.resp_body
  end

  test "passes conn downstream if idempotency is not present in headers" do
    orig_request_id = "test4"
    body = "testing"
    status = 200

    conn =
      :post
      |> conn("/cofe")
      |> Conn.put_resp_header("x-request-id", orig_request_id)
      |> Conn.put_resp_content_type("application/json")
      |> IdempotencyPlug.call([])
      |> Conn.send_resp(status, body)

    assert [] = Conn.get_resp_header(conn, "idempotency-key")
  end

  test "doesn't work with GET/DELETE" do
    key = "test3"
    body = "testing"
    status = 200

    conn =
      :get
      |> conn("/cofe")
      |> put_req_header("idempotency-key", key)
      |> IdempotencyPlug.call([])
      |> Conn.send_resp(status, body)

    assert [] = Conn.get_resp_header(conn, "idempotency-key")

    conn =
      :delete
      |> conn("/cofe")
      |> put_req_header("idempotency-key", key)
      |> IdempotencyPlug.call([])
      |> Conn.send_resp(status, body)

    assert [] = Conn.get_resp_header(conn, "idempotency-key")
  end
end
