# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Migrators.SearchWindowTokensMigrator do
  @moduledoc """
  Builds the `objects_fts` index with window tokens in the background, once,
  after the upgrade migration dropped the plain index
  (`Pleroma.Search.DatabaseSearch.Index.rebuild/2`, concurrently).

  The state is the `search_window_tokens` row in `data_migrations`:

  - `:pending` or `:running`: build after startup. `:running` at startup means
    that a build was interrupted or runs on another node.
  - `:complete`: built, already had tokens, or RUM is used.
  - `:failed`: the build failed. It is not retried automatically; run
    `mix pleroma.database search_window_tokens enable`.
  - `:manual` (or listed in `[:instance, :manual_data_migrations]`): skipped.

  While another session builds or maintains `objects` (for example another
  node), it tries again later.

  This is not a `Pleroma.Migrators.Support.BaseMigrator`: that one processes
  records in batches and has no "try again later".
  """

  use GenServer, restart: :temporary

  require Logger

  alias Pleroma.Config
  alias Pleroma.DataMigration
  alias Pleroma.Search.DatabaseSearch.Index

  @name "search_window_tokens"
  @start_delay :timer.minutes(1)
  @retry_interval :timer.minutes(10)

  @retry_hint "Search works, but slowly, until objects_fts has window tokens. " <>
                "To build them, run `mix pleroma.database search_window_tokens enable` " <>
                "(or `./bin/pleroma_ctl database search_window_tokens enable`)."

  @doc """
  Options: `:delay` before the first run in ms, `:rebuild` options for
  `Index.rebuild/2`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # No database work here, so that it can never delay or break startup.
    Process.send_after(self(), :perform, Keyword.get(opts, :delay, @start_delay))
    {:ok, opts}
  end

  @impl true
  def handle_info(:perform, opts) do
    case run(Keyword.get(opts, :rebuild, [])) do
      :retry ->
        Process.send_after(self(), :perform, @retry_interval)
        {:noreply, opts}

      _ ->
        {:stop, :normal, opts}
    end
  end

  @doc """
  Runs the data migration once. Returns `:complete`, `:failed`, `:retry`, or
  `:skip` if there is nothing to do.
  """
  def run(rebuild_opts \\ []) do
    data_migration = DataMigration.search_window_tokens()

    if runnable?(data_migration), do: perform(data_migration, rebuild_opts), else: :skip
  end

  defp runnable?(%DataMigration{state: state}) when state in [:pending, :running],
    do: @name not in Config.get([:instance, :manual_data_migrations], [])

  defp runnable?(_data_migration), do: false

  defp perform(data_migration, rebuild_opts) do
    if Config.get([:database, :rum_enabled]) do
      complete(data_migration, "RUM is enabled; window tokens are for the GIN index.")
    else
      update(data_migration, :running, "Started the window token rebuild of objects_fts.")

      log(
        "Starting the window token rebuild of objects_fts in the background. " <>
          "Search is slow until it is done."
      )

      :tokens
      |> Index.rebuild(Keyword.put_new(rebuild_opts, :log, &log/1))
      |> finish(data_migration)
    end
  rescue
    error -> fail(data_migration, Exception.message(error))
  end

  defp finish({:ok, :rebuilt}, data_migration),
    do: complete(data_migration, "objects_fts now has window tokens.")

  defp finish({:ok, :unchanged}, data_migration),
    do: complete(data_migration, "objects_fts already has window tokens.")

  defp finish({:error, :rum}, data_migration),
    do: complete(data_migration, "objects_fts is a RUM index; window tokens are for GIN.")

  # Another session (for example on another node) builds or maintains objects.
  defp finish({:error, :running}, _data_migration) do
    log(
      "Another session is building an index or running maintenance on objects; " <>
        "trying again in #{div(@retry_interval, 60_000)} minutes."
    )

    :retry
  end

  defp finish({:error, reason}, data_migration), do: fail(data_migration, inspect(reason))

  defp complete(data_migration, message) do
    log(message)
    update(data_migration, :complete, message)
    :complete
  end

  defp fail(data_migration, reason) do
    message = "Building objects_fts with window tokens failed: #{reason}. " <> @retry_hint
    Logger.error("#{inspect(__MODULE__)}: " <> message)
    update(data_migration, :failed, message)
    :failed
  end

  defp update(%DataMigration{id: id}, state, message),
    do: DataMigration.update_one_by_id(id, state: state, data: %{"message" => message})

  defp log(message), do: Logger.info("#{inspect(__MODULE__)}: " <> message)
end
