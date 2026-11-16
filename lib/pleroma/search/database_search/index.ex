# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearch.Index do
  @moduledoc """
  Rebuilds the `objects_fts` GIN index with or without window tokens
  (see `Pleroma.Search.DatabaseSearch.WindowTokens`).

  The new index is built under a temporary name, then swapped in by renaming,
  so search always has an index. Leftovers of an interrupted run are dropped
  first.
  """

  alias Pleroma.Repo
  alias Pleroma.Search.DatabaseSearch.WindowTokens

  # Temporary names of new indexes while they are built, by form.
  @temporary %{tokens: "objects_fts_windowed", plain: "objects_fts_plain"}
  @old "objects_fts_old"

  # Two rebuilds at the same time would drop each other's new index.
  @lock_key 7_365_000_001

  @doc "SQL that returns the definition of a valid `objects_fts` on `objects`, or NULL."
  def definition_sql do
    "(SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i " <>
      "WHERE i.indexrelid = to_regclass('objects_fts') AND i.indrelid = 'objects'::regclass " <>
      "AND i.indisvalid)"
  end

  @doc "The active form of `objects_fts` and leftovers of interrupted rebuilds."
  def status do
    %{rows: [[definition]]} = query("SELECT " <> definition_sql())

    %{rows: leftovers} =
      query(
        "SELECT c.relname, i.indisvalid, pg_get_indexdef(i.indexrelid) " <>
          "FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " <>
          "WHERE c.oid IN (to_regclass($1), to_regclass($2), to_regclass($3)) " <>
          "AND i.indrelid = 'objects'::regclass ORDER BY c.relname",
        [@temporary.tokens, @temporary.plain, @old]
      )

    %{
      form: WindowTokens.form(definition),
      definition: definition,
      leftovers:
        Enum.map(leftovers, fn [name, valid, definition] ->
          %{name: name, valid: valid, definition: definition}
        end),
      building: building()
    }
  end

  @doc """
  Rebuilds `objects_fts` in `form` (`:tokens` or `:plain`).

  Options:
  - `:config` - text search config, default: the database's default
  - `:force` - rebuild also if `form` is already active (default: false)
  - `:concurrently` - build without blocking writes (default: true; must be
    false inside a transaction)
  - `:log` - function called with progress messages
  """
  def rebuild(form, opts \\ []) when form in [:tokens, :plain] do
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    concurrently = if Keyword.get(opts, :concurrently, true), do: "CONCURRENTLY ", else: ""

    # One connection, so that the session settings and the lock apply to all steps.
    Repo.checkout(
      fn ->
        # The build can take hours; the server's or role's timeouts must not cancel it.
        query("SET statement_timeout = 0")
        query("SET lock_timeout = 0")

        try do
          with_lock(fn ->
            config = Keyword.get_lazy(opts, :config, &default_config/0)
            rebuild(status(), form, config, concurrently, Keyword.get(opts, :force, false), log)
          end)
        after
          # The connection goes back to the pool.
          query("RESET statement_timeout")
          query("RESET lock_timeout")
        end
      end,
      timeout: :infinity
    )
  end

  defp rebuild(%{form: :rum}, _form, _config, _concurrently, _force, _log), do: {:error, :rum}

  # Never drop an index that another session is still building.
  defp rebuild(%{building: [_ | _]}, _form, _config, _concurrently, _force, _log),
    do: {:error, :running}

  defp rebuild(current, form, config, concurrently, force, log) do
    {reusable, others} = Enum.split_with(current.leftovers, &reusable?(&1, form, config))

    # A valid index other than the replaced old one may be wanted (for example
    # built by hand), so it is never dropped automatically.
    case Enum.find(others, &(&1.valid and &1.name != @old)) do
      %{name: name} ->
        {:error, {:leftover, name}}

      nil when current.form == form and not force ->
        drop_leftovers(current.leftovers, concurrently, log)
        # A switch that was interrupted after the rename may have missed this.
        if Enum.any?(others, &(&1.name == @old)), do: analyze(log)
        {:ok, :unchanged}

      nil ->
        drop_leftovers(others, concurrently, log)
        build_or_reuse(reusable, form, config, concurrently, log)
    end
  rescue
    error in Postgrex.Error -> {:error, {:failed, Exception.message(error)}}
  end

  defp build_or_reuse([%{name: name}], _form, _config, concurrently, log) do
    log.("Using the existing valid #{name}")
    switch(name, concurrently, log)
  end

  defp build_or_reuse([], form, config, concurrently, log),
    do: build(form, config, concurrently, log)

  defp with_lock(fun) do
    case query("SELECT pg_try_advisory_lock($1)", [@lock_key]) do
      %{rows: [[true]]} ->
        try do
          fun.()
        after
          query("SELECT pg_advisory_unlock($1)", [@lock_key])
        end

      _ ->
        {:error, :running}
    end
  end

  defp drop_leftovers(leftovers, concurrently, log) do
    Enum.each(leftovers, fn %{name: name} ->
      log.("Dropping #{name}, left over from an earlier run")
      query("DROP INDEX #{concurrently}IF EXISTS #{name}")
    end)
  end

  # A valid index from an earlier run (or built by hand) with the same expression.
  defp reusable?(%{name: name, valid: true, definition: definition}, form, config) do
    name == @temporary[form] and definition =~ "USING gin" and
      WindowTokens.form(definition) == form and
      definition =~ "to_tsvector('#{normalize_config(config)}'::regconfig"
  end

  defp reusable?(_leftover, _form, _config), do: false

  defp build(form, config, concurrently, log) do
    name = @temporary[form]

    log.(
      "Building the #{form} index #{name} with text search config #{config}. " <>
        "This reads the whole objects table and can take hours on large instances; " <>
        "it needs disk space for a second index until it is done."
    )

    query(
      "CREATE INDEX #{concurrently}#{name} ON objects USING gin " <>
        "((#{WindowTokens.index_expression(form, config)}))"
    )

    if valid?(name), do: switch(name, concurrently, log), else: {:error, :invalid}
  end

  defp switch(name, concurrently, log) do
    log.("Switching to the new index")
    swap(name)
    finish_switch(concurrently, log)
  end

  defp finish_switch(concurrently, log) do
    log.("Dropping the old index (waits for queries that still use it)")
    query("DROP INDEX #{concurrently}IF EXISTS #{@old}")
    analyze(log)
    {:ok, :rebuilt}
  rescue
    error in Postgrex.Error -> {:error, {:after_switch, Exception.message(error)}}
  end

  # Statistics of the new index expression, for the planner.
  defp analyze(log) do
    log.("Analyzing objects")
    query("ANALYZE objects")
  end

  # Other sessions holding the lock that CREATE INDEX CONCURRENTLY holds on
  # objects while it runs. pg_locks is readable for every role, but
  # pg_stat_activity hides other roles' sessions, so only sessions visible as
  # autovacuum are left out.
  defp building do
    %{rows: rows} =
      query(
        # pg_locks covers every database; other databases can have the same oid.
        "SELECT DISTINCT l.pid FROM pg_locks l LEFT JOIN pg_stat_activity a ON a.pid = l.pid " <>
          "WHERE l.relation = 'objects'::regclass " <>
          "AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database()) " <>
          "AND l.mode = 'ShareUpdateExclusiveLock' " <>
          "AND l.granted AND l.pid <> pg_backend_pid() " <>
          "AND a.backend_type IS DISTINCT FROM 'autovacuum worker' " <>
          "AND a.backend_type IS DISTINCT FROM 'parallel worker'"
      )

    List.flatten(rows)
  end

  defp normalize_config(config) do
    %{rows: [[normalized]]} = query("SELECT $1::text::regconfig::text", [config])
    normalized
  end

  defp valid?(name) do
    %{rows: rows} =
      query("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", [name])

    rows == [[true]]
  end

  defp swap(name) do
    {:ok, _} =
      Repo.transaction(fn ->
        query("ALTER INDEX IF EXISTS objects_fts RENAME TO #{@old}")
        query("ALTER INDEX #{name} RENAME TO objects_fts")
      end)
  end

  defp default_config do
    %{rows: [[config]]} = query("SELECT current_setting('default_text_search_config')")
    config
  end

  defp query(sql, params \\ []), do: Repo.query!(sql, params, timeout: :infinity)
end
