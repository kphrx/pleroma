# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.AppTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.OAuth.App
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
    # Create an orphaned app (no user_id)
    attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
    {:ok, %App{} = old_app} = App.get_or_make(attrs, ["write"])

    # Create a non-orphaned app with a user
    user = insert(:user)
    attrs = %{client_name: "PleromaFE", redirect_uris: ".", user_id: user.id}
    {:ok, %App{} = kept_app} = App.get_or_make(attrs, ["write"])

    # Create an old but non-orphaned app
    attrs = %{client_name: "OldButValid", redirect_uris: ".", user_id: user.id}
    {:ok, %App{} = old_kept_app} = App.get_or_make(attrs, ["write"])

    # backdate both old apps so they're within the threshold for being cleaned up
    # 1 hour ago
    past_time = NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)

    {:ok, _} =
      Repo.query(
        "UPDATE apps SET inserted_at = $1 WHERE id IN ($2, $3)",
        [past_time, old_app.id, old_kept_app.id]
      )

    # Ensure the updates were applied
    updated_app = Repo.get(App, old_app.id)
    updated_kept_app = Repo.get(App, old_kept_app.id)

    assert NaiveDateTime.compare(
             updated_app.inserted_at,
             NaiveDateTime.add(NaiveDateTime.utc_now(), -900)
           ) == :lt

    assert NaiveDateTime.compare(
             updated_kept_app.inserted_at,
             NaiveDateTime.add(NaiveDateTime.utc_now(), -900)
           ) == :lt

    App.remove_orphans()

    # Verify the orphaned app was removed
    assert is_nil(Repo.get(App, old_app.id))
    # Verify both non-orphaned apps still exist, regardless of age
    assert Repo.get(App, kept_app.id)
    assert Repo.get(App, old_kept_app.id)
  end
end
