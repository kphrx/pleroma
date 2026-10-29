# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearchWindowTokensTest do
  # Rebuilding objects_fts locks the objects table until the test ends.
  use Pleroma.DataCase, async: false

  alias Pleroma.Search.DatabaseSearch, as: Search
  alias Pleroma.Search.DatabaseSearch.Index
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  setup do
    {:ok, :rebuilt} = Index.rebuild(:tokens, concurrently: false)
    :ok
  end

  defp capture_candidate_queries(fun) do
    test_pid = self()
    handler = "window-tokens-test-#{inspect(test_pid)}"

    :telemetry.attach(
      handler,
      [:pleroma, :repo, :query],
      fn _event, _measurements, %{query: query, params: params}, _ ->
        if self() == test_pid and query =~ "websearch_to_tsquery" and query =~ ~s(FROM "objects") do
          send(test_pid, {:candidate_query, query, params})
        end
      end,
      nil
    )

    try do
      {fun.(), receive_queries([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp receive_queries(queries) do
    receive do
      {:candidate_query, query, params} -> receive_queries([{query, params} | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  # Makes the next object id the first of a bucket, minus `before`.
  defp start_bucket_in(before) do
    bucket = Pleroma.Search.DatabaseSearch.WindowTokens.bucket_size()

    Repo.query!(
      "SELECT setval('objects_id_seq', (nextval('objects_id_seq') / $1 + 2) * $1 - $2 - 1)",
      [bucket, before]
    )
  end

  test "finds posts newest first through the token index" do
    user = insert(:user)

    ids =
      for n <- 1..3 do
        {:ok, post} = CommonAPI.post(user, %{status: "wednesday number #{n}"})
        post.id
      end

    {result, [{sql, params} | _]} =
      capture_candidate_queries(fn -> Search.search(nil, "wednesday") end)

    assert Enum.reverse(ids) == Enum.map(result, & &1.id)
    assert sql =~ "|| ('W' ||"

    Repo.query!("SET LOCAL enable_seqscan = off")
    %{rows: plan} = Repo.query!("EXPLAIN " <> sql, params)
    assert plan |> List.flatten() |> Enum.join("\n") =~ "objects_fts"
  end

  test "searches a token window and the rest below it" do
    clear_config([Search, :windows], [1])
    user = insert(:user)
    # The oldest two posts end up in the bucket below the newest one.
    start_bucket_in(2)

    ids =
      for n <- 1..3 do
        {:ok, post} = CommonAPI.post(user, %{status: "wednesday number #{n}"})
        post.id
      end

    {result, queries} = capture_candidate_queries(fn -> Search.search(nil, "wednesday") end)

    assert Enum.reverse(ids) == Enum.map(result, & &1.id)
    assert [{_, newest}, {_, rest}] = queries
    assert Enum.any?(newest, &(is_binary(&1) and &1 =~ ~r/^W\d+$/))
    assert Enum.any?(rest, &(is_binary(&1) and &1 =~ ~r/^!\(W\d+\)$/))
  end

  test "pages and stops like the plain index" do
    clear_config([Search, :windows], [1])
    user = insert(:user)

    [_, middle, oldest] =
      for n <- 1..3 do
        {:ok, post} = CommonAPI.post(user, %{status: "wednesday number #{n}"})
        post.id
      end
      |> Enum.reverse()

    assert [middle] == Search.search(nil, "wednesday", limit: 1, offset: 1) |> Enum.map(& &1.id)
    assert [oldest] == Search.search(nil, "wednesday", limit: 1, offset: 2) |> Enum.map(& &1.id)

    clear_config([Search, :time_budget], 0)
    assert [_newest] = Search.search(nil, "wednesday")
  end

  test "applies the same visibility checks" do
    user = insert(:user)
    reader = insert(:user)
    blocked = insert(:user)

    {:ok, public} = CommonAPI.post(user, %{status: "wednesday public"})

    {:ok, unlisted} =
      CommonAPI.post(user, %{status: "wednesday unlisted", visibility: "unlisted"})

    {:ok, local} = CommonAPI.post(user, %{status: "wednesday local", visibility: "local"})
    {:ok, _} = CommonAPI.post(user, %{status: "wednesday private", visibility: "private"})
    {:ok, by_blocked} = CommonAPI.post(blocked, %{status: "wednesday blocked"})
    {:ok, _} = User.block(reader, blocked)

    assert Enum.sort([public.id, unlisted.id, by_blocked.id]) ==
             Search.search(nil, "wednesday") |> Enum.map(& &1.id) |> Enum.sort()

    assert Enum.sort([public.id, unlisted.id, local.id]) ==
             Search.search(reader, "wednesday") |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "finds nothing for queries without words" do
    {:ok, _} = CommonAPI.post(insert(:user), %{status: "the wednesday"})

    assert [] == Search.search(nil, "the")
    assert [] == Search.search(nil, "...")
  end

  test "finds posts in a window over several buckets" do
    clear_config([Search, :windows], [20_000])
    user = insert(:user)
    {:ok, older} = CommonAPI.post(user, %{status: "wednesday older"})
    start_bucket_in(0)
    {:ok, newer} = CommonAPI.post(user, %{status: "wednesday newer"})

    {result, [{sql, params} | _]} =
      capture_candidate_queries(fn -> Search.search(nil, "wednesday") end)

    assert [newer.id, older.id] == Enum.map(result, & &1.id)
    assert Enum.any?(params, &(is_binary(&1) and &1 =~ ~r/^W\d+( \| W\d+)+$/))

    Repo.query!("SET LOCAL enable_seqscan = off")
    %{rows: plan} = Repo.query!("EXPLAIN " <> sql, params)
    assert plan |> List.flatten() |> Enum.join("\n") =~ "objects_fts"
  end

  test "keeps the id range for windows too wide for tokens" do
    clear_config([Search, :windows], [10_000_000])
    # The window needs ids above its size.
    Repo.query!("SELECT setval('objects_id_seq', greatest(nextval('objects_id_seq'), 20000000))")
    {:ok, post} = CommonAPI.post(insert(:user), %{status: "wednesday"})

    {result, [{sql, _} | _]} =
      capture_candidate_queries(fn -> Search.search(nil, "wednesday") end)

    assert [post.id] == Enum.map(result, & &1.id)
    assert sql =~ ~s/(o0."id" > $/
  end

  test "uses the plain index again after switching back" do
    {:ok, :rebuilt} = Index.rebuild(:plain, concurrently: false)
    {:ok, post} = CommonAPI.post(insert(:user), %{status: "wednesday"})

    {result, [{sql, _} | _]} =
      capture_candidate_queries(fn -> Search.search(nil, "wednesday") end)

    assert [post.id] == Enum.map(result, & &1.id)
    refute sql =~ "|| ('W' ||"
  end
end
