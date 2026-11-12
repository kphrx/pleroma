# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Migrators.SearchWindowTokensMigratorTest do
  # Rebuilding objects_fts locks the objects table until the test ends.
  use Pleroma.DataCase, async: false

  import ExUnit.CaptureLog

  alias Pleroma.DataMigration
  alias Pleroma.Migrators.SearchWindowTokensMigrator, as: Migrator
  alias Pleroma.Search.DatabaseSearch.Index

  # Tests run in a transaction, where CREATE INDEX CONCURRENTLY is not allowed.
  @opts [concurrently: false]

  # The upgrade migration dropped the plain index, so objects_fts is missing here.
  test "builds the token index and completes" do
    assert %{form: :missing} = Index.status()

    log = capture_log(fn -> assert :complete = Migrator.run(@opts) end)

    assert %{form: :tokens} = Index.status()
    assert %DataMigration{state: :complete} = DataMigration.search_window_tokens()
    assert log =~ "Building the tokens index"
  end

  test "only completes if objects_fts already has tokens" do
    {:ok, :rebuilt} = Index.rebuild(:tokens, concurrently: false)
    %{definition: definition} = Index.status()

    log = capture_log(fn -> assert :complete = Migrator.run(@opts) end)

    assert %{form: :tokens, definition: ^definition} = Index.status()
    assert %DataMigration{state: :complete} = DataMigration.search_window_tokens()
    refute log =~ "Building the tokens index"
  end

  test "swaps in a valid prebuilt objects_fts_windowed" do
    Repo.query!(
      "CREATE INDEX objects_fts_windowed ON objects USING gin ((" <>
        Pleroma.Search.DatabaseSearch.WindowTokens.index_expression(:tokens, "english") <> "))"
    )

    log = capture_log(fn -> assert :complete = Migrator.run(@opts ++ [config: "english"]) end)

    assert %{form: :tokens, leftovers: []} = Index.status()
    assert log =~ "Using the existing valid objects_fts_windowed"
    refute log =~ "Building the tokens index"
  end

  test "completes without building with RUM" do
    clear_config([:database, :rum_enabled], true)

    assert :complete = Migrator.run(@opts)

    assert %{form: :missing} = Index.status()
    assert %DataMigration{state: :complete} = DataMigration.search_window_tokens()
  end

  test "retries later, and does not fail, while another session builds" do
    with_lock_in_other_session(fn ->
      capture_log(fn -> assert :retry = Migrator.run(@opts) end)
    end)

    assert %{form: :missing} = Index.status()
    assert %DataMigration{state: :running} = DataMigration.search_window_tokens()
  end

  test "builds again after an interrupted build" do
    set_state(:running)

    capture_log(fn -> assert :complete = Migrator.run(@opts) end)
    assert %{form: :tokens} = Index.status()
  end

  test "keeps an objects_fts it does not know and waits for the admin" do
    Repo.query!("CREATE INDEX objects_fts ON objects (id)")

    log = capture_log(fn -> assert :manual = Migrator.run(@opts) end)

    assert %{form: :unknown} = Index.status()
    assert %DataMigration{state: :manual} = DataMigration.search_window_tokens()
    assert log =~ "search_window_tokens enable"
  end

  test "retries later after a connection error" do
    log = fn _ -> raise DBConnection.ConnectionError, "connection lost" end

    capture_log(fn -> assert :retry = Migrator.run(@opts ++ [log: log]) end)
    assert %DataMigration{state: :running} = DataMigration.search_window_tokens()
  end

  test "fails on other errors" do
    log = fn _ -> raise "boom" end

    capture_log(fn -> assert :failed = Migrator.run(@opts ++ [log: log]) end)
    assert %DataMigration{state: :failed} = DataMigration.search_window_tokens()
  end

  test "retries the cleanup if only the cleanup after the switch failed" do
    # A plain index that the switch replaces and the cleanup has to drop.
    {:ok, :rebuilt} = Index.rebuild(:plain, concurrently: false)

    log = fn
      "Dropping the old index" <> _ -> raise %Postgrex.Error{message: "cleanup failed"}
      _ -> :ok
    end

    output = capture_log(fn -> assert :retry = Migrator.run(@opts ++ [log: log]) end)

    assert %{form: :tokens, leftovers: [%{name: "objects_fts_old"}]} = Index.status()
    assert %DataMigration{state: :running} = DataMigration.search_window_tokens()
    assert output =~ "cleanup failed"

    # The next run only removes the old index.
    assert :complete = Migrator.run(@opts)
    assert %{form: :tokens, leftovers: []} = Index.status()
    assert %DataMigration{state: :complete} = DataMigration.search_window_tokens()
  end

  test "marks a failed build as failed, says how to retry, and does not run again" do
    log =
      capture_log(fn -> assert :failed = Migrator.run(@opts ++ [config: "no_such_config"]) end)

    assert log =~ "no_such_config"
    assert log =~ "search_window_tokens enable"
    assert %DataMigration{state: :failed} = DataMigration.search_window_tokens()

    assert :skip = Migrator.run(@opts)
    assert %{form: :missing} = Index.status()
  end

  test "does nothing once complete or in manual mode" do
    set_state(:complete)
    assert :skip = Migrator.run(@opts)

    set_state(:manual)
    assert :skip = Migrator.run(@opts)

    assert %{form: :missing} = Index.status()
  end

  test "does nothing if listed in manual_data_migrations" do
    clear_config([:instance, :manual_data_migrations], ["search_window_tokens"])

    assert :skip = Migrator.run(@opts)
    assert %{form: :missing} = Index.status()
  end

  test "the process builds after its delay and stops" do
    pid = start_supervised!({Migrator, delay: 0, rebuild: @opts})
    ref = Process.monitor(pid)

    capture_log(fn -> assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000 end)

    assert %{form: :tokens} = Index.status()
    assert %DataMigration{state: :complete} = DataMigration.search_window_tokens()
  end

  test "the process stays and retries while another session builds" do
    with_lock_in_other_session(fn ->
      capture_log(fn ->
        pid = start_supervised!({Migrator, delay: 0, rebuild: @opts})
        # The first run is done when the state is :running and the process is idle.
        assert_state(:running)
        :sys.get_state(pid)
        assert Process.alive?(pid)
      end)
    end)
  end

  defp assert_state(state, tries \\ 50) do
    case DataMigration.search_window_tokens() do
      %DataMigration{state: ^state} ->
        :ok

      _ when tries > 0 ->
        Process.sleep(20)
        assert_state(state, tries - 1)

      other ->
        flunk("data migration state: #{inspect(other.state)}")
    end
  end

  defp set_state(state) do
    :ok = DataMigration.update_one_by_id(DataMigration.search_window_tokens().id, state: state)
  end

  # Index.rebuild's lock, held by a connection outside the test's sandbox, like another node's.
  defp with_lock_in_other_session(fun) do
    {:ok, other} = Postgrex.start_link(other_session_config())
    Postgrex.query!(other, "SELECT pg_advisory_lock(7365000001)", [])

    try do
      fun.()
    after
      # Unlock first: the server can release it later than the connection closes.
      Postgrex.query!(other, "SELECT pg_advisory_unlock(7365000001)", [])
      GenServer.stop(other)
    end
  end

  defp other_session_config do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :database])
    |> Keyword.update(:port, 5432, &to_port/1)
  end

  defp to_port(port) when is_binary(port), do: String.to_integer(port)
  defp to_port(port), do: port
end
