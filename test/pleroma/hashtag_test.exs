# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HashtagTest do
  use Pleroma.DataCase

  alias Pleroma.Hashtag

  describe "changeset validations" do
    test "ensure non-blank :name" do
      changeset = Hashtag.changeset(%Hashtag{}, %{name: ""})

      assert {:name, {"can't be blank", [validation: :required]}} in changeset.errors
    end
  end

  describe "search_hashtags" do
    test "searches hashtags by partial match" do
      {:ok, _} = Hashtag.get_or_create_by_name("car")
      {:ok, _} = Hashtag.get_or_create_by_name("racecar")
      {:ok, _} = Hashtag.get_or_create_by_name("nascar")
      {:ok, _} = Hashtag.get_or_create_by_name("bicycle")

      results = Hashtag.search("car")
      assert "car" in results
      assert "racecar" in results
      assert "nascar" in results
      refute "bicycle" in results

      results = Hashtag.search("race")
      assert "racecar" in results
      refute "car" in results
      refute "nascar" in results
      refute "bicycle" in results

      results = Hashtag.search("nonexistent")
      assert results == []
    end

    test "supports pagination" do
      {:ok, _} = Hashtag.get_or_create_by_name("alpha")
      {:ok, _} = Hashtag.get_or_create_by_name("beta")
      {:ok, _} = Hashtag.get_or_create_by_name("gamma")
      {:ok, _} = Hashtag.get_or_create_by_name("delta")

      results = Hashtag.search("a", limit: 2)
      assert length(results) == 2

      results = Hashtag.search("a", limit: 2, offset: 1)
      assert length(results) == 2
    end
  end
end
