# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.TokenControllerTest do
  use Pleroma.Web.ConnCase, async: true

  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.OAuth.Token

  import Pleroma.Factory

  describe "GET /api/account/confirm_email/:id/:token" do
    setup do
      {:ok, user} =
        insert(:user)
        |> User.confirmation_changeset(set_confirmation: false)
        |> Repo.update()

      refute user.is_confirmed

      [user: user]
    end

    test "it redirects to root url", %{conn: conn, user: user} do
      conn = get(conn, "/api/account/confirm_email/#{user.id}/#{user.confirmation_token}")

      assert 302 == conn.status
    end

    test "it confirms the user account", %{conn: conn, user: user} do
      get(conn, "/api/account/confirm_email/#{user.id}/#{user.confirmation_token}")

      user = User.get_cached_by_id(user.id)

      assert user.is_confirmed
      refute user.confirmation_token
    end

    test "it returns 500 if user cannot be found by id", %{conn: conn, user: user} do
      conn = get(conn, "/api/account/confirm_email/0/#{user.confirmation_token}")

      assert 500 == conn.status
    end

    test "it returns 500 if token is invalid", %{conn: conn, user: user} do
      conn = get(conn, "/api/account/confirm_email/#{user.id}/wrong_token")

      assert 500 == conn.status
    end
  end

  describe "GET /api/oauth_tokens" do
    test "renders list" do
      %{conn: conn} = oauth_access(["read:security"])

      keys =
        conn
        |> get("/api/oauth_tokens")
        |> json_response(200)
        |> hd()
        |> Map.keys()

      assert Enum.sort(keys) == Enum.sort(["id", "app_name", "valid_until", "scopes"])
    end

    test "is allowed with the read scope" do
      %{conn: conn} = oauth_access(["read"])

      assert [_] = conn |> get("/api/oauth_tokens") |> json_response(200)
    end

    test "is forbidden without read:security" do
      %{conn: conn} = oauth_access(["profile", "read:accounts", "write:security"])

      assert %{"error" => "Insufficient permissions: read:security."} =
               conn |> get("/api/oauth_tokens") |> json_response(403)
    end
  end

  describe "DELETE /api/oauth_tokens/:id" do
    test "revokes the token" do
      %{conn: conn, user: user, token: token} = oauth_access(["write:security"])
      other = insert(:oauth_token, user: user)

      conn = delete(conn, "/api/oauth_tokens/#{other.id}")

      assert conn.status == 201
      assert [%Token{id: id}] = Token.get_user_tokens(user)
      assert id == token.id
    end

    test "is allowed with the write scope" do
      %{conn: conn, user: user} = oauth_access(["write"])
      other = insert(:oauth_token, user: user)

      assert delete(conn, "/api/oauth_tokens/#{other.id}").status == 201
    end

    test "is forbidden without write:security" do
      %{conn: conn, user: user} = oauth_access(["profile", "read", "write:accounts"])
      other = insert(:oauth_token, user: user)

      assert %{"error" => "Insufficient permissions: write:security."} =
               conn |> delete("/api/oauth_tokens/#{other.id}") |> json_response(403)

      assert length(Token.get_user_tokens(user)) == 2
    end
  end
end
