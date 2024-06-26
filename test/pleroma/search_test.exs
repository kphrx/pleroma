# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.SearchTest do
  use Pleroma.DataCase, async: true
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.SearchIndexingWorker

  test "indexes posts that are public" do
    user = insert(:user)

    {:ok, activity} =
      CommonAPI.post(user, %{
        status: "Well this is a story all about how my life got flipped turned upside down",
        visibility: "public"
      })

    args = %{"op" => "add_to_index", "activity" => activity.id}

    assert_enqueued(worker: SearchIndexingWorker, args: args)
  end

  test "doesn't index posts that are not public" do
    user = insert(:user)

    Enum.each(["private", "direct"], fn visibility ->
      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "guys i just don't wanna leave the swamp",
          visibility: visibility
        })

      args = %{"op" => "add_to_index", "activity" => activity.id}

      refute_enqueued(worker: SearchIndexingWorker, args: args)
    end)
  end

  test "Indexes appropriate activity types" do
    user = insert(:user)

    {:ok, activity} =
      CommonAPI.post(user, %{
        status: "I'm my own hype man",
        visibility: "public"
      })

    args = %{"op" => "add_to_index", "activity" => activity.id}

    assert_enqueued(worker: SearchIndexingWorker, args: args)

    {:ok, fav_activity} = CommonAPI.favorite(user, activity.id)

    args = %{"op" => "add_to_index", "activity" => fav_activity.id}

    refute_enqueued(worker: SearchIndexingWorker, args: args)

    {:ok, repeat_activity} = CommonAPI.repeat(activity.id, user)

    args = %{"op" => "add_to_index", "activity" => repeat_activity.id}

    refute_enqueued(worker: SearchIndexingWorker, args: args)
  end
end
