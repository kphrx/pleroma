# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.ObjectAgePolicyTest do
  use Pleroma.DataCase
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.MRF.ObjectAgePolicy
  alias Pleroma.Web.ActivityPub.Visibility

  require Pleroma.Constants

  setup do:
          clear_config(:mrf_object_age,
            threshold: 172_800,
            actions: [:delist, :strip_followers]
          )

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  defp get_old_message do
    File.read!("test/fixtures/mastodon-post-activity.json")
    |> Jason.decode!()
    |> Map.drop(["published"])
  end

  defp get_new_message do
    old_message = get_old_message()

    new_object =
      old_message
      |> Map.get("object")
      |> Map.put("published", DateTime.utc_now() |> DateTime.to_iso8601())

    old_message
    |> Map.put("object", new_object)
  end

  describe "with reject action" do
    test "works with objects with empty to or cc fields" do
      clear_config([:mrf_object_age, :actions], [:reject])

      data =
        get_old_message()
        |> Map.put("cc", nil)
        |> Map.put("to", nil)

      assert match?({:reject, _}, ObjectAgePolicy.filter(data))
    end

    test "it rejects an old post" do
      clear_config([:mrf_object_age, :actions], [:reject])

      data = get_old_message()

      assert match?({:reject, _}, ObjectAgePolicy.filter(data))
    end

    test "it allows a new post" do
      clear_config([:mrf_object_age, :actions], [:reject])

      data = get_new_message()

      assert match?({:ok, _}, ObjectAgePolicy.filter(data))
    end
  end

  describe "with delist action" do
    test "works with objects with empty to or cc fields" do
      clear_config([:mrf_object_age, :actions], [:delist])

      data =
        get_old_message()
        |> Map.put("cc", nil)
        |> Map.put("to", nil)

      {:ok, _u} = User.get_or_fetch_by_ap_id(data["actor"])

      {:ok, data} = ObjectAgePolicy.filter(data)

      assert Visibility.get_visibility(%{data: data}) == "direct"
    end

    test "it delists an old post" do
      clear_config([:mrf_object_age, :actions], [:delist])

      data = get_old_message()

      {:ok, _u} = User.get_or_fetch_by_ap_id(data["actor"])

      {:ok, data} = ObjectAgePolicy.filter(data)

      assert Visibility.get_visibility(%{data: data}) == "unlisted"
    end

    test "it keeps an old followers-only post private" do
      clear_config([:mrf_object_age, :actions], [:delist])

      data = get_old_message()
      {:ok, user} = User.get_or_fetch_by_ap_id(data["actor"])

      data =
        data
        |> Map.put("to", [user.follower_address])
        |> Map.put("cc", [])
        |> put_in(["object", "to"], [user.follower_address])
        |> put_in(["object", "cc"], [])

      {:ok, data} = ObjectAgePolicy.filter(data)

      assert data["to"] == [user.follower_address]
      assert data["cc"] == []
      assert Visibility.get_visibility(%{data: data}) == "private"
      assert data["object"]["to"] == data["to"]
      assert data["object"]["cc"] == data["cc"]
    end

    test "it keeps an old direct message direct" do
      clear_config([:mrf_object_age, :actions], [:delist])

      data = get_old_message()
      {:ok, _user} = User.get_or_fetch_by_ap_id(data["actor"])
      recipient = "https://example.com/users/someone"

      data =
        data
        |> Map.put("to", [recipient])
        |> Map.put("cc", [])
        |> put_in(["object", "to"], [recipient])
        |> put_in(["object", "cc"], [])

      {:ok, data} = ObjectAgePolicy.filter(data)

      assert data["to"] == [recipient]
      assert data["cc"] == []
      assert Visibility.get_visibility(%{data: data}) == "direct"
    end

    test "it removes every copy of the follower address" do
      clear_config([:mrf_object_age, :actions], [:strip_followers])

      data = get_old_message()
      {:ok, user} = User.get_or_fetch_by_ap_id(data["actor"])
      public = Pleroma.Constants.as_public()
      followers = [user.follower_address, user.follower_address]

      data =
        data
        |> Map.put("to", [public])
        |> Map.put("cc", followers)
        |> put_in(["object", "to"], [public])
        |> put_in(["object", "cc"], followers)

      {:ok, data} = ObjectAgePolicy.filter(data)

      assert data["to"] == [public]
      assert data["cc"] == []
    end

    test "it does not duplicate addresses of an old unlisted post" do
      clear_config([:mrf_object_age, :actions], [:delist, :strip_followers])

      data = get_old_message()
      {:ok, user} = User.get_or_fetch_by_ap_id(data["actor"])
      public = Pleroma.Constants.as_public()

      data =
        data
        |> Map.put("to", [user.follower_address])
        |> Map.put("cc", [public])
        |> put_in(["object", "to"], [user.follower_address])
        |> put_in(["object", "cc"], [public])

      {:ok, data} = ObjectAgePolicy.filter(data)

      assert data["to"] == []
      assert data["cc"] == [public]
    end

    test "it allows a new post" do
      clear_config([:mrf_object_age, :actions], [:delist])

      data = get_new_message()

      {:ok, _user} = User.get_or_fetch_by_ap_id(data["actor"])

      assert match?({:ok, ^data}, ObjectAgePolicy.filter(data))
    end
  end

  describe "with strip_followers action" do
    test "works with objects with empty to or cc fields" do
      clear_config([:mrf_object_age, :actions], [:strip_followers])

      data =
        get_old_message()
        |> Map.put("cc", nil)
        |> Map.put("to", nil)

      {:ok, user} = User.get_or_fetch_by_ap_id(data["actor"])

      {:ok, data} = ObjectAgePolicy.filter(data)

      refute user.follower_address in data["to"]
      refute user.follower_address in data["cc"]
    end

    test "it strips followers collections from an old post" do
      clear_config([:mrf_object_age, :actions], [:strip_followers])

      data = get_old_message()

      {:ok, user} = User.get_or_fetch_by_ap_id(data["actor"])

      {:ok, data} = ObjectAgePolicy.filter(data)

      refute user.follower_address in data["to"]
      refute user.follower_address in data["cc"]
    end

    test "it allows a new post" do
      clear_config([:mrf_object_age, :actions], [:strip_followers])

      data = get_new_message()

      {:ok, _u} = User.get_or_fetch_by_ap_id(data["actor"])

      assert match?({:ok, ^data}, ObjectAgePolicy.filter(data))
    end
  end
end
