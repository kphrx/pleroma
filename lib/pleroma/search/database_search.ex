# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearch do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.Pagination
  alias Pleroma.Repo
  alias Pleroma.Search.DatabaseSearch.Index
  alias Pleroma.Search.DatabaseSearch.WindowTokens
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Visibility

  require Pleroma.Constants

  import Ecto.Query

  @behaviour Pleroma.Search.SearchBackend

  # Newest object ids searched first, each window older than the one before.
  @default_windows [10_000, 100_000, 1_000_000]
  @default_time_budget 10_000

  @impl true
  def search(user, search_query, options \\ []) do
    index_type = if Config.get([:database, :rum_enabled]), do: :rum, else: :gin
    limit = Enum.min([Keyword.get(options, :limit), 40])
    offset = Keyword.get(options, :offset, 0)
    author = Keyword.get(options, :author)

    activities =
      try do
        with_fuzzy_limit(fn ->
          do_search(index_type, user, search_query, author, offset, limit)
        end)
      rescue
        _ -> []
      end

    # Outside the query transaction, as it may fetch over the network.
    maybe_fetch(activities, user, search_query)
  end

  defp do_search(:rum, user, search_query, author, offset, limit) do
    user
    |> visible_activities(author, blocked_ap_ids(user))
    |> query_with(:rum, search_query)
    |> Pagination.fetch_paginated(
      %{"offset" => offset, "limit" => limit, "skip_order" => true},
      :offset
    )
  end

  # Searching all matches and sorting them is linear in the number of matches,
  # which is too slow for common words on large databases. Instead, search the
  # objects newest first in growing id windows and stop once there are enough
  # results or the time budget is spent. Only the candidates are joined to
  # their activities, where the exact visibility checks are applied.
  defp do_search(:gin, user, search_query, author, offset, limit) do
    case Repo.aggregate(Object, :max, :id) do
      nil ->
        []

      max_id ->
        {:ok, activities} =
          Repo.transaction(fn ->
            gin_search(max_id, user, search_query, author, offset, limit)
          end)

        activities
    end
  end

  defp gin_search(max_id, user, search_query, author, offset, limit) do
    case text_search_setup(search_query) do
      # Only stop words: nothing to search for (and with window tokens, an
      # empty query would match every post in a window).
      {_tsc, _tokens, 0} ->
        []

      {tsc, tokens, _nodes} ->
        gin_search(max_id, user, search_query, author, offset, limit, tsc, tokens)
    end
  end

  defp gin_search(max_id, user, search_query, author, offset, limit, tsc, tokens) do
    budget = Config.get([__MODULE__, :time_budget]) || @default_time_budget
    wanted = offset + limit
    original = current_settings()

    search = %{
      user: user,
      author: author,
      blocked: blocked_ap_ids(user),
      local: restrict_local?(user),
      query: search_query,
      tsc: tsc,
      tokens: tokens,
      max_id: max_id,
      batch: max(2 * wanted, 40),
      budget: budget,
      deadline: System.monotonic_time(:millisecond) + budget,
      original: original
    }

    search
    |> collect(window_bounds(max_id), max_id + 1, [], wanted)
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  @doc false
  # Lower bounds (exclusive) of the id windows, newest first, then all older ids.
  def window_bounds(max_id) do
    [__MODULE__, :windows]
    |> Config.get(@default_windows)
    |> Enum.filter(&(&1 > 0))
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.map(&(max_id - &1))
    |> Enum.filter(&(&1 > 0))
    |> Kernel.++([:rest])
  end

  defp collect(_search, [], _upper, found, _wanted), do: found

  defp collect(search, [lower | older] = bounds, upper, found, wanted) do
    case search_window(search, lower, upper) do
      :canceled ->
        found

      {ids, activities} ->
        found = found ++ activities

        cond do
          length(found) >= wanted -> found
          System.monotonic_time(:millisecond) >= search.deadline -> found
          # The window has more candidates: continue below the last one.
          length(ids) == search.batch -> collect(search, bounds, List.last(ids), found, wanted)
          lower == :rest -> found
          true -> collect(search, older, lower + 1, found, wanted)
        end
    end
  end

  defp search_window(search, lower, upper) do
    case window_tokens(search, lower, upper) do
      :empty -> {[], []}
      tokens -> search_window(search, lower, upper, tokens)
    end
  end

  defp window_tokens(%{tokens: false}, _lower, _upper), do: :plain
  defp window_tokens(search, :rest, upper), do: WindowTokens.rest(upper, search.max_id)
  defp window_tokens(_search, lower, upper), do: WindowTokens.window(lower, upper)

  defp search_window(search, lower, upper, tokens) do
    # When the planner underestimates the matches (common for several words),
    # it scans a whole window through objects_pkey and runs to_tsvector on
    # every row. Bitmap scans, which combine both indexes, stay allowed.
    settings = %{"enable_indexscan" => "off", "statement_timeout" => statement_timeout(search)}

    case with_local_settings(settings, search.original, fn ->
           search |> candidate_query(lower, upper, tokens) |> Repo.all(mode: :savepoint)
         end) do
      {:ok, ids} -> {ids, fetch_activities(search, ids)}
      :canceled -> :canceled
    end
  end

  @doc false
  # Runs `fun` with `settings` set, then restores `original`, also when
  # statement_timeout cancels a query in `fun` (which returns :canceled).
  # Queries in `fun` must use `mode: :savepoint` to keep the transaction usable.
  def with_local_settings(settings, original, fun) do
    set_local(settings)

    result =
      try do
        {:ok, fun.()}
      rescue
        error in Postgrex.Error ->
          if canceled?(error), do: :canceled, else: reraise(error, __STACKTRACE__)
      end

    restore_settings(Map.take(original, Map.keys(settings)), 2)
    result
  end

  # The restore runs under the short timeout too; retry if it is cancelled.
  defp restore_settings(settings, attempts) do
    set_local(settings, mode: :savepoint)
  rescue
    error in Postgrex.Error ->
      if canceled?(error) and attempts > 1,
        do: restore_settings(settings, attempts - 1),
        else: reraise(error, __STACKTRACE__)
  end

  defp canceled?(error), do: match?(%{postgres: %{code: :query_canceled}}, error)

  # Each query gets the rest of the time budget, but not more than the server allows.
  defp statement_timeout(%{budget: 0, original: original}), do: original["statement_timeout"]

  defp statement_timeout(%{deadline: deadline, original: original}) do
    # At least 50 ms, so that restoring the settings afterwards has time to run.
    remaining = max(deadline - System.monotonic_time(:millisecond), 50)

    case String.to_integer(original["statement_timeout"]) do
      0 -> Integer.to_string(remaining)
      server -> Integer.to_string(min(server, remaining))
    end
  end

  defp current_settings do
    %{rows: rows} =
      Repo.query!(
        "SELECT name, setting FROM pg_settings WHERE name IN ('enable_indexscan', 'statement_timeout')"
      )

    Map.new(rows, &List.to_tuple/1)
  end

  defp set_local(settings, opts \\ []) do
    calls =
      settings
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {_, i} -> "set_config($#{2 * i + 1}, $#{2 * i + 2}, true)" end)

    params = Enum.flat_map(settings, fn {name, value} -> [name, value] end)
    Repo.query!("SELECT " <> calls, params, opts)
  end

  defp candidate_query(search, lower, upper, tokens) do
    recipients = intended_recipients(search.user)

    from(o in Object,
      # Cheap pre-filter on the object's own addressing; the activity's is checked later.
      where:
        fragment(
          "(?->'to') \\?| ? OR (?->'cc') \\?| ?",
          o.data,
          ^recipients,
          o.data,
          ^recipients
        ),
      # `+ 0`: never walk objects_pkey backwards running to_tsvector on every row.
      order_by: [desc: fragment("? + 0", o.id)],
      limit: ^search.batch,
      select: o.id
    )
    |> restrict_text(search, tokens)
    |> restrict_window(lower, upper, tokens)
    |> prefilter_local(search.local)
    |> prefilter_author(search.author)
    |> prefilter_blocked(search.blocked)
  end

  # With window tokens, the expressions must be the same as the index's.
  defmacrop token_match(tsc, data, id, query, tokens) do
    sql =
      WindowTokens.vector_sql() <>
        " @@ (websearch_to_tsquery(?::oid::regconfig, ?) && ?::text::tsquery)"

    quote do
      fragment(
        unquote(sql),
        unquote(tsc),
        unquote(data),
        unquote(id),
        unquote(tsc),
        unquote(query),
        unquote(tokens)
      )
    end
  end

  defmacrop token_match(tsc, data, id, query) do
    sql = WindowTokens.vector_sql() <> " @@ websearch_to_tsquery(?::oid::regconfig, ?)"

    quote do
      fragment(
        unquote(sql),
        unquote(tsc),
        unquote(data),
        unquote(id),
        unquote(tsc),
        unquote(query)
      )
    end
  end

  defp restrict_text(query, %{tsc: tsc, query: text}, :plain) do
    where(
      query,
      [o],
      fragment(
        "to_tsvector(?::oid::regconfig, ?->>'content') @@ websearch_to_tsquery(?::oid::regconfig, ?)",
        ^tsc,
        o.data,
        ^tsc,
        ^text
      )
    )
  end

  defp restrict_text(query, %{tsc: tsc, query: text}, :none),
    do: where(query, [o], token_match(^tsc, o.data, o.id, ^text))

  defp restrict_text(query, %{tsc: tsc, query: text}, {:tokens, tokens}),
    do: where(query, [o], token_match(^tsc, o.data, o.id, ^text, ^tokens))

  # Without tokens, the newest windows combine the GIN index with objects_pkey;
  # the rest uses only the GIN index, as a range over most of the table would
  # be expensive. With tokens, the GIN index finds the window's buckets, and
  # the exact bounds are checked on the rows.
  defp restrict_window(query, :rest, upper, _tokens),
    do: where(query, [o], fragment("? + 0", o.id) < ^upper)

  defp restrict_window(query, lower, upper, tokens) when tokens in [:plain, :none],
    do: where(query, [o], o.id > ^lower and o.id < ^upper)

  defp restrict_window(query, lower, upper, {:tokens, _}),
    do: where(query, [o], fragment("? + 0", o.id) > ^lower and fragment("? + 0", o.id) < ^upper)

  # Pre-filters on the object's actor; the activity's actor is checked later.
  defmacrop object_actor(data) do
    quote do
      fragment("coalesce(?->>'actor', ?->>'attributedTo', '')", unquote(data), unquote(data))
    end
  end

  defp prefilter_local(query, false), do: query

  defp prefilter_local(query, true),
    do: where(query, [o], fragment("starts_with(?, ?)", object_actor(o.data), ^local_prefix()))

  defp prefilter_author(query, %User{ap_id: ap_id}),
    do: where(query, [o], object_actor(o.data) == ^ap_id)

  defp prefilter_author(query, _), do: query

  defp prefilter_blocked(query, []), do: query

  defp prefilter_blocked(query, blocked),
    do: where(query, [o], object_actor(o.data) not in ^blocked)

  defp local_prefix, do: Pleroma.Web.Endpoint.url() <> "/"

  defp fetch_activities(_search, []), do: []

  defp fetch_activities(search, ids) do
    search.user
    |> visible_activities(search.author, search.blocked)
    |> where([a, o], o.id in ^ids)
    |> order_by([a, o], desc: o.id)
    |> Repo.all()
  end

  defp visible_activities(user, author, blocked) do
    Activity
    |> Activity.with_preloaded_object()
    |> Activity.restrict_deactivated_users()
    |> restrict_public(user)
    |> maybe_restrict_local(user)
    |> maybe_restrict_author(author)
    |> Activity.Queries.exclude_authors(blocked)
  end

  defp blocked_ap_ids(%User{} = user), do: User.blocked_users_ap_ids(user)
  defp blocked_ap_ids(_), do: []

  @doc """
  Runs `fun` with `gin_fuzzy_search_limit` set, if configured under
  `Pleroma.Search.DatabaseSearch`. A limit makes GIN scans faster but their
  results incomplete and random, so it is only set for search queries. 0 sets
  exact results even if the server has a limit; nil keeps the server's value.
  """
  def with_fuzzy_limit(fun) do
    case Config.get([__MODULE__, :gin_fuzzy_search_limit]) do
      limit when is_integer(limit) and limit >= 0 ->
        {:ok, result} =
          Repo.transaction(fn ->
            # SET LOCAL takes no parameters; limit is an integer.
            Repo.query!("SET LOCAL gin_fuzzy_search_limit TO #{limit}")
            fun.()
          end)

        result

      _ ->
        fun.()
    end
  end

  @impl true
  def add_to_index(_activity), do: :ok

  @impl true
  def remove_from_index(_object), do: :ok

  @impl true
  def create_index, do: :ok

  @impl true
  def drop_index, do: :ok

  @impl true
  def healthcheck_endpoints, do: nil

  def maybe_restrict_author(query, %User{} = author) do
    Activity.Queries.by_author(query, author)
  end

  def maybe_restrict_author(query, _), do: query

  def maybe_restrict_blocked(query, %User{} = user) do
    Activity.Queries.exclude_authors(query, User.blocked_users_ap_ids(user))
  end

  def maybe_restrict_blocked(query, _), do: query

  defp intended_recipients(nil), do: [Pleroma.Constants.as_public()]

  defp intended_recipients(_user),
    do: [Pleroma.Constants.as_public(), Pleroma.Web.ActivityPub.Utils.as_local_public()]

  defp restrict_public(q, nil) do
    from([a, o] in q,
      where: fragment("?->>'type' = 'Create'", a.data),
      where: ^Pleroma.Constants.as_public() in a.recipients
    )
  end

  defp restrict_public(q, user) do
    from([a, o] in q,
      where: fragment("?->>'type' = 'Create'", a.data),
      where: fragment("? && ?", ^intended_recipients(user), a.recipients)
    )
  end

  # The index form is read on every search, so switching it needs no restart.
  defp text_search_setup(search_query) do
    %{rows: [[tsc, definition, nodes]]} =
      Repo.query!(
        "SELECT current_setting('default_text_search_config')::regconfig::oid, " <>
          Index.definition_sql() <>
          ", numnode(websearch_to_tsquery(current_setting('default_text_search_config')::regconfig, $1))",
        [search_query]
      )

    {tsc, WindowTokens.form(definition) == :tokens, nodes}
  end

  defp query_with(q, :rum, search_query) do
    from([a, o] in q,
      where:
        fragment(
          "? @@ websearch_to_tsquery(?)",
          o.fts_content,
          ^search_query
        ),
      order_by: [fragment("? <=> now()::date", o.inserted_at)]
    )
  end

  def maybe_restrict_local(q, user) do
    if restrict_local?(user), do: restrict_local(q), else: q
  end

  defp restrict_local?(user) do
    limit = Config.get([:instance, :limit_to_local_content], :unauthenticated)

    case {limit, user} do
      {:all, _} -> true
      {:unauthenticated, %User{}} -> false
      {:unauthenticated, _} -> true
      {false, _} -> false
    end
  end

  defp restrict_local(q), do: where(q, local: true)

  def maybe_fetch(activities, user, search_query) do
    with true <- Regex.match?(~r/https?:/, search_query),
         {:ok, object} <- Fetcher.fetch_object_from_id(search_query),
         %Activity{} = activity <- Activity.get_create_by_object_ap_id(object.data["id"]),
         true <- Visibility.visible_for_user?(activity, user) do
      [activity | activities]
    else
      _ -> activities
    end
  end
end
