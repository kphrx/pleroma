# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.ListViewTest do
  use Pleroma.DataCase, async: true
  import Pleroma.Factory
  alias Pleroma.Web.MastodonAPI.ListView

  test "show" do
    user = insert(:user)
    title = "mortal enemies"
    {:ok, list} = Pleroma.List.create(%{title: title}, user)

    expected = %{
      id: to_string(list.id),
      title: title,
      exclusive: false,
      pleroma: %{
        emoji: nil,
        emoji_url: nil
      }
    }

    assert expected == ListView.render("show.json", %{list: list})
  end

  test "show with a unicode emoji" do
    user = insert(:user)
    {:ok, list} = Pleroma.List.create(%{title: "mortal enemies", emoji: "🕓"}, user)

    assert %{
             pleroma: %{
               emoji: "🕓",
               emoji_url: nil
             }
           } = ListView.render("show.json", %{list: list})
  end

  test "index" do
    user = insert(:user)

    {:ok, list} = Pleroma.List.create(%{title: "my list", exclusive: false}, user)
    {:ok, list2} = Pleroma.List.create(%{title: "cofe", exclusive: true}, user)

    assert [
             %{id: _, title: "my list", exclusive: false},
             %{id: _, title: "cofe", exclusive: true}
           ] =
             ListView.render("index.json", lists: [list, list2])
  end
end
