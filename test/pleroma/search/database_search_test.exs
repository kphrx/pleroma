# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearchTest do
  alias Pleroma.Search.DatabaseSearch, as: Search
  alias Pleroma.Web.CommonAPI
  import Pleroma.Factory

  use Pleroma.DataCase, async: true

  alias Pleroma.Activity
  alias Pleroma.User

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

  describe "ordering and pagination" do
    setup do
      user = insert(:user)

      posts =
        for n <- 1..3 do
          {:ok, post} = CommonAPI.post(user, %{status: "wednesday number #{n}"})
          post
        end

      %{user: user, ids: posts |> Enum.reverse() |> Enum.map(& &1.id)}
    end

    test "returns the newest posts first", %{ids: ids} do
      assert ids == Search.search(nil, "wednesday") |> Enum.map(& &1.id)
    end

    test "pages with offset and limit", %{ids: [_newest, middle, oldest]} do
      assert [middle] == Search.search(nil, "wednesday", limit: 1, offset: 1) |> Enum.map(& &1.id)
      assert [oldest] == Search.search(nil, "wednesday", limit: 5, offset: 2) |> Enum.map(& &1.id)
      assert [] == Search.search(nil, "wednesday", limit: 5, offset: 3)
    end
  end

  describe "id windows" do
    setup do
      user = insert(:user)
      clear_config([Search, :windows], [1])

      posts =
        for n <- 1..3 do
          {:ok, post} = CommonAPI.post(user, %{status: "wednesday number #{n}"})
          post
        end

      %{ids: posts |> Enum.reverse() |> Enum.map(& &1.id)}
    end

    defp count_candidate_queries(fun) do
      test_pid = self()
      handler = "search-test-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:pleroma, :repo, :query],
        fn _event, _measurements, %{query: query}, _ ->
          if self() == test_pid and query =~ "websearch_to_tsquery" do
            send(test_pid, :candidate_query)
          end
        end,
        nil
      )

      try do
        {fun.(), count_messages(:candidate_query, 0)}
      after
        :telemetry.detach(handler)
      end
    end

    defp count_messages(message, count) do
      receive do
        ^message -> count_messages(message, count + 1)
      after
        0 -> count
      end
    end

    test "stops after the newest window when it has enough results", %{ids: [newest | _]} do
      {result, queries} =
        count_candidate_queries(fn -> Search.search(nil, "wednesday", limit: 1) end)

      assert [newest] == Enum.map(result, & &1.id)
      assert queries == 1
    end

    test "moves on to older windows until it has enough results", %{ids: ids} do
      {result, queries} = count_candidate_queries(fn -> Search.search(nil, "wednesday") end)

      assert ids == Enum.map(result, & &1.id)
      assert queries == 2
    end

    test "continues in a window when its candidates are filtered out" do
      clear_config([Search, :windows], [])
      %Activity{id: visible_id} = insert(:note_activity)
      spammer = insert(:user)

      # More hidden candidates than one batch holds.
      for _ <- 1..41, do: insert(:note_activity, user: spammer)
      {:ok, _} = User.set_activation(spammer, false)

      {result, queries} =
        count_candidate_queries(fn -> Search.search(nil, "moominmamma", limit: 1) end)

      assert [visible_id] == Enum.map(result, & &1.id)
      assert queries == 2
    end

    test "pages across windows", %{ids: [_newest, middle, oldest]} do
      assert [middle] == Search.search(nil, "wednesday", limit: 1, offset: 1) |> Enum.map(& &1.id)
      assert [oldest] == Search.search(nil, "wednesday", limit: 1, offset: 2) |> Enum.map(& &1.id)
    end

    test "returns each post once with unsorted windows", %{ids: ids} do
      clear_config([Search, :windows], [100_000, 1, 1])

      assert ids == Search.search(nil, "wednesday") |> Enum.map(& &1.id)
    end

    test "returns the results found so far when the time budget is spent", %{ids: [newest | _]} do
      clear_config([Search, :time_budget], 0)

      assert [newest] == Search.search(nil, "wednesday") |> Enum.map(& &1.id)
    end
  end

  describe "visibility and restrictions" do
    test "finds public and unlisted posts, but not private or direct ones" do
      user = insert(:user)
      reader = insert(:user)

      {:ok, public} = CommonAPI.post(user, %{status: "wednesday public"})

      {:ok, unlisted} =
        CommonAPI.post(user, %{status: "wednesday unlisted", visibility: "unlisted"})

      {:ok, _} = CommonAPI.post(user, %{status: "wednesday private", visibility: "private"})

      {:ok, _} =
        CommonAPI.post(user, %{
          status: "@#{reader.nickname} wednesday direct",
          visibility: "direct"
        })

      expected = Enum.sort([public.id, unlisted.id])

      assert expected == Search.search(nil, "wednesday") |> Enum.map(& &1.id) |> Enum.sort()
      assert expected == Search.search(reader, "wednesday") |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "uses the activity's addressing, not only the object's" do
      user = insert(:user)
      note = insert(:note, user: user, data: %{"content" => "wednesday leak"})
      insert(:note_activity, user: user, note: note, recipients: [user.follower_address])

      assert [] == Search.search(nil, "wednesday")
      assert [] == Search.search(insert(:user), "wednesday")
    end

    test "excludes posts of blocked and deactivated users" do
      reader = insert(:user)
      blocked = insert(:user)
      deactivated = insert(:user)
      other = insert(:user)

      {:ok, _} = CommonAPI.post(blocked, %{status: "wednesday blocked"})
      {:ok, _} = CommonAPI.post(deactivated, %{status: "wednesday deactivated"})
      {:ok, post} = CommonAPI.post(other, %{status: "wednesday fine"})
      {:ok, _} = User.block(reader, blocked)
      {:ok, _} = User.set_activation(deactivated, false)

      assert [post.id] == Search.search(reader, "wednesday") |> Enum.map(& &1.id)
    end

    test "filters by author" do
      user = insert(:user)
      other = insert(:user)
      {:ok, post} = CommonAPI.post(user, %{status: "wednesday mine"})
      {:ok, _} = CommonAPI.post(other, %{status: "wednesday theirs"})

      assert [post.id] == Search.search(nil, "wednesday", author: user) |> Enum.map(& &1.id)
    end

    test "finds remote posts only where local content is not restricted" do
      remote = insert(:user, local: false, ap_id: "https://example.com/users/remote")

      %Activity{id: remote_id} =
        insert(:note_activity, user: remote, local: false, object_local: false)

      {:ok, %{id: local_id}} = CommonAPI.post(insert(:user), %{status: "a moominmamma"})
      reader = insert(:user)

      clear_config([:instance, :limit_to_local_content], :unauthenticated)
      assert [local_id] == Search.search(nil, "moominmamma") |> Enum.map(& &1.id)
      assert [local_id, remote_id] == Search.search(reader, "moominmamma") |> Enum.map(& &1.id)

      clear_config([:instance, :limit_to_local_content], :all)
      assert [local_id] == Search.search(reader, "moominmamma") |> Enum.map(& &1.id)

      clear_config([:instance, :limit_to_local_content], false)
      assert [local_id, remote_id] == Search.search(nil, "moominmamma") |> Enum.map(& &1.id)
    end
  end

  test "restores the session's planner and timeout settings" do
    {:ok, _} = CommonAPI.post(insert(:user), %{status: "wednesday"})
    Pleroma.Repo.query!("SET statement_timeout = 12345")

    assert [_] = Search.search(nil, "wednesday")

    assert %{rows: [["12345ms"]]} = Pleroma.Repo.query!("SHOW statement_timeout")
    assert %{rows: [["on"]]} = Pleroma.Repo.query!("SHOW enable_indexscan")
  end

  test "uses the database's text search configuration" do
    {:ok, post} = CommonAPI.post(insert(:user), %{status: "my dudes"})

    assert [%{id: id}] = Search.search(nil, "dude")
    assert id == post.id

    Pleroma.Repo.query!("SET default_text_search_config = 'simple'")
    assert [] == Search.search(nil, "dude")
    assert [%{id: ^id}] = Search.search(nil, "dudes")
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

    test "nil keeps a limit set elsewhere, 0 overrides it" do
      Pleroma.Repo.query!("SET gin_fuzzy_search_limit = 77")

      clear_config([Search, :gin_fuzzy_search_limit], nil)
      assert Search.with_fuzzy_limit(&fuzzy_limit/0) == "77"

      clear_config([Search, :gin_fuzzy_search_limit], 0)
      assert Search.with_fuzzy_limit(&fuzzy_limit/0) == "0"
    end

    test "search still works with a limit" do
      clear_config([Search, :gin_fuzzy_search_limit], 10_000)
      {:ok, post} = CommonAPI.post(insert(:user), %{status: "it's wednesday my dudes"})

      assert [%{id: id}] = Search.search(nil, "wednesday")
      assert id == post.id
    end
  end
end
