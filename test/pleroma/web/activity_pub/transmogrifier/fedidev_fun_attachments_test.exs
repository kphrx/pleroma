# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.FedidevFunAttachmentsTest do
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

  defp ingest_fixture!(rel_path) do
    data = rel_path |> File.read!() |> Jason.decode!()
    ensure_remote_actor!(data["actor"])

    assert {:ok, activity} = Transmogrifier.handle_incoming(data)
    object = Object.normalize(activity.data["object"], fetch: false)

    {activity, object}
  end

  test "drops non-http(s) attachment href" do
    {_activity, object} = ingest_fixture!("test/fixtures/fedidev.fun/attachment_payto_link.json")
    assert object.data["attachment"] == []
  end

  test "drops embedded non-attachment objects" do
    {_activity, object} =
      ingest_fixture!("test/fixtures/fedidev.fun/attachment_embedded_note.json")

    assert object.data["attachment"] == []
  end

  test "accepts attachment url as list and keeps the first link" do
    {_activity, object} = ingest_fixture!("test/fixtures/fedidev.fun/attachment_url_list.json")

    [attachment] = object.data["attachment"]
    [%{"href" => href} | _] = attachment["url"]

    assert href == "https://fedidev.fun/images/007.png"
  end
end
