# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearchTest do
  alias Pleroma.Search.DatabaseSearch, as: Search
  alias Pleroma.Web.CommonAPI
  import Pleroma.Factory

  use Pleroma.DataCase, async: true

  test "it finds something" do
    user = insert(:user)
    {:ok, post} = CommonAPI.post(user, %{status: "it's wednesday my dudes"})

    [result] = Search.search(nil, "wednesday")

    assert result.id == post.id
  end

  test "it finds local-only posts for authenticated users" do
    user = insert(:user)
    reader = insert(:user)
    {:ok, post} = CommonAPI.post(user, %{status: "it's wednesday my dudes", visibility: "local"})

    [result] = Search.search(reader, "wednesday")

    assert result.id == post.id
  end

  test "it does not find local-only posts for anonymous users" do
    user = insert(:user)
    {:ok, _post} = CommonAPI.post(user, %{status: "it's wednesday my dudes", visibility: "local"})

    assert [] = Search.search(nil, "wednesday")
  end

  test "using websearch_to_tsquery" do
    user = insert(:user)
    {:ok, _post} = CommonAPI.post(user, %{status: "it's wednesday my dudes"})
    {:ok, other_post} = CommonAPI.post(user, %{status: "it's wednesday my bros"})

    assert [result] = Search.search(nil, "wednesday -dudes")

    assert result.id == other_post.id
  end

  describe "gin_fuzzy_search_limit" do
    defp fuzzy_limit do
      %{rows: [[value]]} = Pleroma.Repo.query!("SHOW gin_fuzzy_search_limit")
      value
    end

    test "is not set on normal database connections" do
      assert fuzzy_limit() == "0"
    end

    test "is only set for the search query when configured" do
      clear_config([Search, :gin_fuzzy_search_limit], nil)
      assert Search.with_fuzzy_limit(&fuzzy_limit/0) == "0"

      clear_config([Search, :gin_fuzzy_search_limit], 10_000)
      assert Search.with_fuzzy_limit(&fuzzy_limit/0) == "10000"
    end

    test "search still works with a limit" do
      clear_config([Search, :gin_fuzzy_search_limit], 10_000)
      {:ok, post} = CommonAPI.post(insert(:user), %{status: "it's wednesday my dudes"})

      assert [%{id: id}] = Search.search(nil, "wednesday")
      assert id == post.id
    end
  end
end
