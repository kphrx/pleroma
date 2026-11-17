# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.HomeTimeline do
  @moduledoc false

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Pagination
  alias Pleroma.Repo

  @minimum_recipients 128
  @candidate_limit 8192
  @budget_ms 250

  # Home selection must be exact, but search still benefits from the configured
  # fuzzy GIN limit. A savepoint also restores settings inside caller transactions
  # (including SQL Sandbox), where SET LOCAL alone would leak into later queries.
  # Only read-only selection belongs here, never rendering or job insertion.
  def with_exact_queries(fun) do
    if Repo.in_transaction?() do
      exact_queries(fun)
    else
      {:ok, result} = Repo.transaction(fn -> exact_queries(fun) end)
      result
    end
  end

  defp exact_queries(fun) do
    read_only_savepoint("home_timeline", fn ->
      Repo.query!("SET LOCAL gin_fuzzy_search_limit = 0")
      fun.()
    end)
  end

  def fetch(recipients, opts, build_query) do
    opts = Map.put(opts, :skip_extra_order, true)

    result =
      if length(recipients) >= @minimum_recipients and opts[:followed_hashtags] in [nil, []] do
        attempt(opts, build_query)
      else
        :fallback
      end

    case result do
      {:ok, activities} ->
        activities

      :fallback ->
        build_query.(Activity, :overlap) |> Pagination.fetch_paginated(opts, :keyset, nil)
    end
  end

  defp attempt(opts, build_query) do
    read_only_savepoint("home_timeline_fast", fn ->
      deadline = System.monotonic_time(:millisecond) + @budget_ms
      set_timeout(@budget_ms)
      options = Pagination.cast_params(opts)
      rows = select_candidates(options, opts, build_query)
      ids = for {id, _count} <- rows, not is_nil(id), do: id
      {_id, count} = hd(rows)

      cond do
        length(ids) < Pagination.page_size(options) and count > @candidate_limit ->
          :fallback

        ids == [] ->
          {:ok, []}

        true ->
          hydrate(ids, opts, build_query, deadline)
      end
    end)
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :query_canceled do
        :fallback
      else
        reraise error, __STACKTRACE__
      end
  end

  defp select_candidates(options, opts, build_query) do
    # The extra ID proves whether the requested range was exhausted. Metadata and
    # filtered IDs are selected in ONE snapshot, including when no posts match.
    range =
      Activity
      |> candidate_order(opts)
      |> Pagination.paginate(options)

    candidates =
      range
      |> limit(^(@candidate_limit + 1))
      |> select([a], %{id: a.id})

    # Both bounded scans share the same range, order and statement snapshot.
    # Keep the activity scan ordered and limited BEFORE every filter; joining
    # candidate IDs back to activities can lose that order and force a full sort.
    source = range |> limit(^@candidate_limit) |> subquery()

    page =
      build_query.(source, :exists)
      |> exclude(:preload)
      |> exclude(:select)
      |> select([a], %{id: a.id})
      |> Pagination.paginate(options)

    metadata = from(c in "home_timeline_candidates", select: %{count: count(c.id)})

    from(m in subquery(metadata),
      left_join: a in subquery(page),
      on: true,
      select: {a.id, m.count}
    )
    |> with_cte("home_timeline_candidates", as: ^candidates, materialized: true)
    |> Repo.all()
  end

  defp candidate_order(query, %{order: direction}) when direction in [:asc, :desc] do
    order_by(query, [a], [{^direction, a.id}])
  end

  defp candidate_order(query, _), do: query

  defp hydrate(ids, opts, build_query, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      set_timeout(remaining)

      # Reload at most one page through the same filters and typed preloads. A
      # concurrent delete/visibility change may remove a post, never add one.
      activities =
        build_query.(Activity, :exists)
        |> where([a], a.id in ^ids)
        |> Pagination.fetch_paginated(opts, :keyset, nil)

      {:ok, activities}
    else
      :fallback
    end
  end

  defp set_timeout(milliseconds) do
    Repo.query!("SELECT set_config('statement_timeout', $1, true)", ["#{milliseconds}ms"])
  end

  defp read_only_savepoint(name, fun) do
    Repo.query!("SAVEPOINT #{name}")

    try do
      fun.()
    after
      # Roll back even on success to restore the caller's settings. This also
      # recovers an aborted transaction after PostgreSQL cancels a slow attempt.
      Repo.query!("ROLLBACK TO SAVEPOINT #{name}")
      Repo.query!("RELEASE SAVEPOINT #{name}")
    end
  end
end
