# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearch.IndexTest do
  # Rebuilding objects_fts locks the objects table until the test ends.
  use Pleroma.DataCase, async: false

  alias Pleroma.Search.DatabaseSearch.Index

  # The upgrade migration drops the plain index; most tests start from it.
  setup do
    {:ok, _} = Index.rebuild(:plain, concurrently: false)
    assert %{form: :plain, leftovers: []} = Index.status()
    :ok
  end

  test "switches to window tokens and back" do
    assert {:ok, :rebuilt} = Index.rebuild(:tokens, concurrently: false)
    assert %{form: :tokens, leftovers: []} = Index.status()

    assert {:ok, :rebuilt} = Index.rebuild(:plain, concurrently: false)
    assert %{form: :plain, leftovers: []} = Index.status()
  end

  test "does nothing if the form is already active, unless forced" do
    assert {:ok, :unchanged} = Index.rebuild(:plain, concurrently: false)
    assert {:ok, :rebuilt} = Index.rebuild(:plain, concurrently: false, force: true)
  end

  test "uses the given text search config" do
    assert {:ok, :rebuilt} = Index.rebuild(:tokens, concurrently: false, config: "simple")
    assert %{form: :tokens, definition: definition} = Index.status()
    assert definition =~ "'simple'::regconfig"
  end

  test "drops leftovers of an interrupted run" do
    Repo.query!("CREATE INDEX objects_fts_plain ON objects (id)")

    Repo.query!(
      "UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'objects_fts_plain'::regclass"
    )

    assert %{leftovers: [%{name: "objects_fts_plain", valid: false}]} = Index.status()

    test_pid = self()
    log = &send(test_pid, {:log, &1})

    assert {:ok, :rebuilt} = Index.rebuild(:tokens, concurrently: false, log: log)
    assert %{form: :tokens, leftovers: []} = Index.status()
    assert_received {:log, "Dropping objects_fts_plain, left over from an earlier run"}
  end

  test "only drops leftovers if the form is already active" do
    Repo.query!("CREATE INDEX objects_fts_old ON objects (id)")
    %{definition: definition} = Index.status()

    test_pid = self()
    log = &send(test_pid, {:log, &1})

    assert {:ok, :unchanged} = Index.rebuild(:plain, concurrently: false, log: log)
    assert %{form: :plain, definition: ^definition, leftovers: []} = Index.status()
    # An interrupted switch may have missed the statistics.
    assert_received {:log, "Analyzing objects"}
  end

  test "keeps a valid leftover it cannot use" do
    Repo.query!("CREATE INDEX objects_fts_windowed ON objects (id)")
    %{definition: definition} = Index.status()

    assert {:error, {:leftover, "objects_fts_windowed"}} =
             Index.rebuild(:tokens, concurrently: false)

    assert %{form: :plain, definition: ^definition} = Index.status()
    assert %{leftovers: [%{name: "objects_fts_windowed", valid: true}]} = Index.status()
  end

  test "replaces a partial or missing objects_fts" do
    Repo.query!("DROP INDEX objects_fts")
    assert %{form: :missing} = Index.status()
    assert {:ok, :rebuilt} = Index.rebuild(:plain, concurrently: false)
    assert %{form: :plain} = Index.status()

    Repo.query!("DROP INDEX objects_fts")

    Repo.query!(
      "CREATE INDEX objects_fts ON objects USING gin (to_tsvector('english', data->>'content')) WHERE id < 0"
    )

    assert %{form: :unknown} = Index.status()

    assert {:ok, :rebuilt} = Index.rebuild(:tokens, concurrently: false)
    assert %{form: :tokens} = Index.status()
  end

  test "builds the token index when objects_fts is missing" do
    Repo.query!("DROP INDEX objects_fts")
    assert %{form: :missing, leftovers: []} = Index.status()

    test_pid = self()
    log = &send(test_pid, {:log, &1})

    assert {:ok, :rebuilt} = Index.rebuild(:tokens, concurrently: false, log: log)
    assert %{form: :tokens, leftovers: []} = Index.status()
    assert_received {:log, "Building" <> _}
    refute_received {:log, "Dropping objects_fts" <> _}
  end

  test "reports a failed build and keeps the index" do
    %{definition: definition} = Index.status()

    assert {:error, {:failed, message}} =
             Index.rebuild(:tokens, concurrently: false, config: "no_such_config")

    assert message =~ "no_such_config"
    assert %{form: :plain, definition: ^definition} = Index.status()
  end

  describe "an objects_fts_windowed built by hand" do
    @expression "(to_tsvector('english'::regconfig, data->>'content') || " <>
                  "('W' || (id / 10000)::text || ' X' || (id / 100000)::text || ' Y' || (id / 1000000)::text)::tsvector)"

    test "is reused when it is valid" do
      Repo.query!("CREATE INDEX objects_fts_windowed ON objects USING gin ((#{@expression}))")

      assert %{form: :plain, leftovers: [%{name: "objects_fts_windowed", valid: true}]} =
               Index.status()

      test_pid = self()
      log = &send(test_pid, {:log, &1})

      assert {:ok, :rebuilt} =
               Index.rebuild(:tokens, concurrently: false, config: "english", log: log)

      assert %{form: :tokens, leftovers: []} = Index.status()
      assert_received {:log, "Using the existing valid objects_fts_windowed"}
      refute_received {:log, "Building" <> _}
    end

    test "is rebuilt when it is invalid" do
      Repo.query!("CREATE INDEX objects_fts_windowed ON objects USING gin ((#{@expression}))")

      Repo.query!(
        "UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'objects_fts_windowed'::regclass"
      )

      assert %{leftovers: [%{name: "objects_fts_windowed", valid: false}]} = Index.status()

      test_pid = self()
      log = &send(test_pid, {:log, &1})

      assert {:ok, :rebuilt} = Index.rebuild(:tokens, concurrently: false, log: log)
      assert %{form: :tokens, leftovers: []} = Index.status()
      assert_received {:log, "Dropping objects_fts_windowed, left over from an earlier run"}
      assert_received {:log, "Building" <> _}
    end

    test "is kept, not replaced, for another text search config" do
      Repo.query!("CREATE INDEX objects_fts_windowed ON objects USING gin ((#{@expression}))")

      assert {:error, {:leftover, "objects_fts_windowed"}} =
               Index.rebuild(:tokens, concurrently: false, config: "simple")

      assert %{form: :plain, leftovers: [%{name: "objects_fts_windowed", valid: true}]} =
               Index.status()
    end
  end
end
