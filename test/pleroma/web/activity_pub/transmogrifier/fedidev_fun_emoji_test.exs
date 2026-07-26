# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.FedidevFunEmojiTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase

  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Pleroma.Factory

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  defp ensure_remote_actor!(ap_id) when is_binary(ap_id) do
    case User.get_cached_by_ap_id(ap_id) do
      %User{} ->
        :ok

      _ ->
        insert(:user,
          local: false,
          ap_id: ap_id,
          follower_address: ap_id <> "/followers",
          following_address: ap_id <> "/following",
          featured_address: ap_id <> "/collections/featured",
          inbox: ap_id <> "/inbox"
        )

        :ok
    end
  end

  defp ingest_data!(data) do
    ensure_remote_actor!(data["actor"])

    assert {:ok, activity} = Transmogrifier.handle_incoming(data)
    object = Object.normalize(activity.data["object"], fetch: false)

    {activity, object}
  end

  defp ingest_fixture!(rel_path) do
    rel_path
    |> File.read!()
    |> Jason.decode!()
    |> ingest_data!()
  end

  test "ingests Emoji tag with string icon" do
    {_activity, object} = ingest_fixture!("test/fixtures/fedidev.fun/emoji_icon_string.json")
    assert object.data["emoji"]["cow"] == "https://fedidev.fun/static/cow.png"
  end

  test "ingests Emoji tag with icon missing type" do
    {_activity, object} =
      ingest_fixture!("test/fixtures/fedidev.fun/emoji_icon_url_missing_type.json")

    assert object.data["emoji"]["cow2"] == "https://fedidev.fun/static/cow.png"
  end

  test "ignores Emoji tag missing icon" do
    {_activity, object} = ingest_fixture!("test/fixtures/fedidev.fun/emoji_missing_icon.json")
    assert object.data["emoji"] == %{}
  end

  test "ignores Emoji tag missing a string name" do
    data = File.read!("test/fixtures/fedidev.fun/emoji_icon_string.json") |> Jason.decode!()
    data = put_in(data, ["object", "tag", Access.at(0), "name"], nil)

    {_activity, object} = ingest_data!(data)

    assert object.data["emoji"] == %{}
  end

  test "ignores Emoji tag with a non-http icon" do
    data = File.read!("test/fixtures/fedidev.fun/emoji_icon_string.json") |> Jason.decode!()
    data = put_in(data, ["object", "tag", Access.at(0), "icon"], "file:///tmp/cow.png")

    {_activity, object} = ingest_data!(data)

    assert object.data["emoji"] == %{}
  end

  test "normalizes a list-typed Emoji tag before building the emoji map" do
    data = File.read!("test/fixtures/fedidev.fun/emoji_icon_string.json") |> Jason.decode!()

    data =
      put_in(data, ["object", "tag", Access.at(0), "type"], [
        "https://example.com/ns#CustomTag",
        "Emoji"
      ])

    {_activity, object} = ingest_data!(data)

    assert object.data["emoji"]["cow"] == "https://fedidev.fun/static/cow.png"
  end
end
