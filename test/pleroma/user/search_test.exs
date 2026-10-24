# Pleroma: A lightweight social networking server
# Copyright © Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.User.SearchTest do
  use Pleroma.DataCase, async: false

  import Pleroma.Factory

  alias Pleroma.Instances
  alias Pleroma.Repo
  alias Pleroma.User

  describe "search/2 mention suggestions" do
    test "prioritizes followed/follower users before others" do
      user = insert(:user)

      related =
        insert(:user,
          local: false,
          nickname: "hj@real.example",
          ap_id: "https://real.example/users/hj",
          last_status_at: ~N[2020-01-01 00:00:00]
        )

      other = insert(:user, nickname: "hj", last_status_at: ~N[2020-01-02 00:00:00])

      {:ok, _related, _user} = User.follow(related, user)

      results = User.search("hj", for_user: user) |> Enum.map(& &1.id)

      assert results == [related.id, other.id]
    end

    test "orders followed/follower users by most recent activity" do
      user = insert(:user)

      older =
        insert(:user,
          local: false,
          nickname: "ali@remote.example",
          ap_id: "https://remote.example/users/ali",
          last_status_at: ~N[2020-01-01 00:00:00]
        )

      newer =
        insert(:user,
          local: false,
          nickname: "alia@remote.example",
          ap_id: "https://remote.example/users/alia",
          last_status_at: ~N[2020-01-02 00:00:00]
        )

      {:ok, _user, _older} = User.follow(user, older)
      {:ok, _user, _newer} = User.follow(user, newer)

      assert [newer.id, older.id] ==
               User.search("ali", for_user: user)
               |> Enum.map(& &1.id)
    end

    test "groups followed/follower users first and sorts them by recency" do
      user = insert(:user)

      following_newest =
        insert(:user,
          local: false,
          nickname: "mentiontesta@related.example",
          ap_id: "https://related.example/users/mentiontesta",
          last_status_at: ~N[2020-01-03 00:00:00]
        )

      follower_middle =
        insert(:user,
          local: false,
          nickname: "mentiontestb@related.example",
          ap_id: "https://related.example/users/mentiontestb",
          last_status_at: ~N[2020-01-02 00:00:00]
        )

      mutual_oldest =
        insert(:user,
          local: false,
          nickname: "mentiontestc@related.example",
          ap_id: "https://related.example/users/mentiontestc",
          last_status_at: ~N[2020-01-01 00:00:00]
        )

      unrelated_newer =
        insert(:user,
          local: false,
          nickname: "mentiontestd@unrelated.example",
          ap_id: "https://unrelated.example/users/mentiontestd",
          last_status_at: ~N[2020-01-04 00:00:00]
        )

      {:ok, _user, _following_newest} = User.follow(user, following_newest)
      {:ok, _follower_middle, _user} = User.follow(follower_middle, user)

      {:ok, _user, _mutual_oldest} = User.follow(user, mutual_oldest)
      {:ok, _mutual_oldest, _user} = User.follow(mutual_oldest, user)

      results = User.search("mentiontest", for_user: user)

      assert Enum.map(results, & &1.id) ==
               [following_newest.id, follower_middle.id, mutual_oldest.id, unrelated_newer.id]
    end

    test "uses last_active_at when last_status_at is missing" do
      user = insert(:user)

      older =
        insert(:user,
          local: false,
          nickname: "activefallbacka@remote.example",
          ap_id: "https://remote.example/users/activefallbacka",
          last_status_at: nil,
          last_active_at: ~N[2020-01-01 00:00:00]
        )

      newer =
        insert(:user,
          local: false,
          nickname: "activefallbackb@remote.example",
          ap_id: "https://remote.example/users/activefallbackb",
          last_status_at: nil,
          last_active_at: ~N[2020-01-02 00:00:00]
        )

      {:ok, _user, _older} = User.follow(user, older)
      {:ok, _user, _newer} = User.follow(user, newer)

      assert [newer.id, older.id] ==
               User.search("activefallback", for_user: user)
               |> Enum.map(& &1.id)
    end

    test "does not return deactivated users even if related" do
      user = insert(:user)

      active =
        insert(:user,
          local: false,
          nickname: "deactivatedtesta@remote.example",
          ap_id: "https://remote.example/users/deactivatedtesta",
          last_status_at: ~N[2020-01-02 00:00:00]
        )

      deactivated =
        insert(:user,
          local: false,
          nickname: "deactivatedtestb@remote.example",
          ap_id: "https://remote.example/users/deactivatedtestb",
          last_status_at: ~N[2020-01-03 00:00:00]
        )

      {:ok, _user, _active} = User.follow(user, active)
      {:ok, _user, _deactivated} = User.follow(user, deactivated)
      Repo.update!(Ecto.Changeset.change(deactivated, is_active: false))

      results = User.search("deactivatedtest", for_user: user) |> Enum.map(& &1.id)

      assert results == [active.id]
    end

    test "does not return users from unreachable instances" do
      user = insert(:user)

      {:ok, _instance} = Instances.set_unreachable("dead.example")

      dead =
        insert(:user,
          local: false,
          nickname: "ali@dead.example",
          ap_id: "https://dead.example/users/ali",
          last_status_at: ~N[2020-01-02 00:00:00]
        )

      alive =
        insert(:user,
          local: false,
          nickname: "ali@alive.example",
          ap_id: "https://alive.example/users/ali",
          last_status_at: ~N[2020-01-02 00:00:00]
        )

      {:ok, _user, _alive} = User.follow(user, alive)
      {:ok, _user, _dead} = User.follow(user, dead)

      results = User.search("ali", for_user: user) |> Enum.map(& &1.id)

      assert results == [alive.id]
    end
  end
end
