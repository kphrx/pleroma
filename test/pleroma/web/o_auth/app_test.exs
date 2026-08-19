# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.AppTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.MFA.Token, as: MFAToken
  alias Pleroma.Web.OAuth.App
  alias Pleroma.Web.OAuth.Authorization
  alias Pleroma.Web.OAuth.Token
  alias Pleroma.Web.Push.Subscription
  import Pleroma.Factory

  describe "get_or_make/2" do
    test "gets exist app" do
      attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
      app = insert(:oauth_app, Map.merge(attrs, %{scopes: ["read", "write"]}))
      {:ok, %App{} = exist_app} = App.get_or_make(attrs, [])
      assert exist_app == app
    end

    test "make app" do
      attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
      {:ok, %App{} = app} = App.get_or_make(attrs, ["write"])
      assert app.scopes == ["write"]
    end

    test "gets exist app and updates scopes" do
      attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
      app = insert(:oauth_app, Map.merge(attrs, %{scopes: ["read", "write"]}))
      {:ok, %App{} = exist_app} = App.get_or_make(attrs, ["read", "write", "follow", "push"])
      assert exist_app.id == app.id
      assert exist_app.scopes == ["read", "write", "follow", "push"]
    end

    test "has unique client_id" do
      insert(:oauth_app, client_name: "", redirect_uris: "", client_id: "boop")

      error =
        catch_error(insert(:oauth_app, client_name: "", redirect_uris: "", client_id: "boop"))

      assert %Ecto.ConstraintError{} = error
      assert error.constraint == "apps_client_id_index"
      assert error.type == :unique
    end
  end

  test "get_user_apps/1" do
    user = insert(:user)

    apps = [
      insert(:oauth_app, user_id: user.id),
      insert(:oauth_app, user_id: user.id),
      insert(:oauth_app, user_id: user.id)
    ]

    assert Enum.sort(App.get_user_apps(user)) == Enum.sort(apps)
  end

  test "removes orphaned apps" do
    attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
    {:ok, %App{} = old_app} = App.get_or_make(attrs, ["write"])
    authorization = insert(:oauth_authorization, app: old_app)
    token = insert(:oauth_token, app: old_app)
    mfa_token = insert(:mfa_token, authorization: authorization)
    push_subscription = insert(:push_subscription, token: token)

    user = insert(:user)
    attrs = %{client_name: "OldButValid", redirect_uris: ".", user_id: user.id}
    {:ok, %App{} = old_owned_app} = App.get_or_make(attrs, ["write"])

    one_hour_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)

    {:ok, _} =
      "UPDATE apps SET inserted_at = $1, updated_at = $1 WHERE id IN ($2, $3)"
      |> Repo.query([one_hour_ago, old_app.id, old_owned_app.id])

    attrs = %{client_name: "PleromaFE", redirect_uris: "."}
    {:ok, %App{} = recent_app} = App.get_or_make(attrs, ["write"])

    App.remove_orphans()

    refute Repo.get(App, old_app.id)
    refute Repo.get(Authorization, authorization.id)
    refute Repo.get(Token, token.id)
    refute Repo.get(MFAToken, mfa_token.id)
    refute Repo.get(Subscription, push_subscription.id)
    assert Repo.get(App, recent_app.id)
    assert Repo.get(App, old_owned_app.id)
  end
end
