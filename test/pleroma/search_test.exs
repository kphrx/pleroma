# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.SearchTest do
  require Pleroma.Constants

  use Pleroma.DataCase, async: true
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.Object
  alias Pleroma.Search
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.SearchIndexingWorker

  test "indexes posts that are public or unlisted" do
    user = insert(:user)

    Enum.each(["public", "unlisted"], fn visibility ->
      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "Well this is a story all about how my life got flipped turned upside down",
          visibility: visibility
        })

      args = %{"op" => "add_to_index", "activity" => activity.id}

      assert_enqueued(worker: SearchIndexingWorker, args: args)
    end)
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

    {:ok, fav_activity} = CommonAPI.favorite(activity.id, user)

    args = %{"op" => "add_to_index", "activity" => fav_activity.id}

    refute_enqueued(worker: SearchIndexingWorker, args: args)

    {:ok, repeat_activity} = CommonAPI.repeat(activity.id, user)

    args = %{"op" => "add_to_index", "activity" => repeat_activity.id}

    refute_enqueued(worker: SearchIndexingWorker, args: args)
  end

  test "object_to_search_data includes content warnings and attachment descriptions" do
    object = %Object{
      id: 1,
      data: %{
        "id" => "https://example.com/objects/1",
        "type" => "Note",
        "content" => "body text",
        "summary" => "subject text",
        "attachment" => [
          %{"type" => "Document", "name" => "image description"},
          %{
            "type" => "Document",
            "name" => "remote-image.jpg",
            "summary" => "remote image description"
          },
          %{"type" => "Document", "name" => ""}
        ],
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    assert %{content: content} = Search.object_to_search_data(object)
    assert content =~ "body text"
    assert content =~ "subject text"
    assert content =~ "image description"
    assert content =~ "remote image description"
    refute content =~ "remote-image.jpg"
  end

  test "object_to_search_data ignores objects with invalid published dates" do
    for published <- [nil, 123, "not a date"] do
      object = %Object{
        id: 1,
        data: %{
          "id" => "https://example.com/objects/1",
          "type" => "Note",
          "content" => "body text",
          "published" => published
        }
      }

      refute Search.object_to_search_data(object)
    end
  end

  test "indexable? accepts searchable content warnings and attachment descriptions" do
    public = Pleroma.Constants.as_public()
    published = DateTime.utc_now() |> DateTime.to_iso8601()

    for data <- [
          %{"content" => ".", "summary" => "subject text", "attachment" => []},
          %{
            "content" => ".",
            "summary" => "",
            "attachment" => [%{"type" => "Document", "name" => "image description"}]
          }
        ] do
      object = %Object{
        id: 1,
        data:
          Map.merge(data, %{
            "id" => "https://example.com/objects/1",
            "type" => "Note",
            "to" => [public],
            "published" => published
          })
      }

      activity = %Pleroma.Activity{
        id: Ecto.UUID.generate(),
        data: %{"type" => "Create"},
        object: object,
        recipients: [public]
      }

      assert Search.indexable?(activity)
    end
  end
end
