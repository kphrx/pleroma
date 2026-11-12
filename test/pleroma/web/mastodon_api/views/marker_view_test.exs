# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.MarkerViewTest do
  use Pleroma.DataCase, async: true
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.Web.MastodonAPI.MarkerView
  import Pleroma.Factory

  test "returns markers" do
    marker1 = insert(:marker, timeline: "notifications", last_read_id: "17", unread_count: 5)
    marker2 = insert(:marker, timeline: "home", last_read_id: "42")

    assert MarkerView.render("markers.json", %{markers: [marker1, marker2]}) == %{
             "home" => %{
               last_read_id: "42",
               updated_at: Utils.to_masto_date(marker2.updated_at),
               version: 0,
               pleroma: %{unread_count: 0}
             },
             "notifications" => %{
               last_read_id: "17",
               updated_at: Utils.to_masto_date(marker1.updated_at),
               version: 0,
               pleroma: %{unread_count: 5}
             }
           }
  end

  test "renders updated_at in the Mastodon date format" do
    marker = insert(:marker, timeline: "home")

    %{"home" => %{updated_at: updated_at}} =
      MarkerView.render("markers.json", %{markers: [marker]})

    assert updated_at =~ ~r/\.\d{3}Z$/
  end
end
