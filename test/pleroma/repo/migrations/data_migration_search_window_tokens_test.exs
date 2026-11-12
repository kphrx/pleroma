# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.DataMigrationSearchWindowTokensTest do
  # Replaces objects_fts, which locks the objects table until the test ends.
  use Pleroma.DataCase, async: false
  import Pleroma.Tests.Helpers

  alias Pleroma.DataMigration
  alias Pleroma.Search.DatabaseSearch.Index

  setup_all do: require_migration("20261030120000_data_migration_search_window_tokens")

  test "registers the data migration" do
    assert %DataMigration{state: :pending} = DataMigration.search_window_tokens()
  end

  describe "plain_gin?/1" do
    test "is true for the plain GIN index", %{migration: migration} do
      {:ok, _} = Index.rebuild(:plain, concurrently: false)
      assert migration.plain_gin?(Repo)
    end

    test "is false for the token index", %{migration: migration} do
      {:ok, _} = Index.rebuild(:tokens, concurrently: false)
      refute migration.plain_gin?(Repo)
    end

    test "is false without objects_fts", %{migration: migration} do
      Repo.query!("DROP INDEX IF EXISTS objects_fts")
      refute migration.plain_gin?(Repo)
    end

    test "is false for other indexes", %{migration: migration} do
      Repo.query!("DROP INDEX IF EXISTS objects_fts")

      Repo.query!(
        "CREATE INDEX objects_fts ON objects USING gin " <>
          "(to_tsvector('english', data->>'content')) WHERE id < 0"
      )

      refute migration.plain_gin?(Repo)

      Repo.query!("DROP INDEX objects_fts")
      Repo.query!("CREATE INDEX objects_fts ON objects (id)")
      refute migration.plain_gin?(Repo)
    end
  end
end
