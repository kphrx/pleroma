defmodule Pleroma.Repo.Migrations.DataMigrationSearchWindowTokens do
  @moduledoc """
  Drops the plain `objects_fts` full-text index to free its disk space, and
  registers the `search_window_tokens` data migration, which builds the index
  with window tokens in the background after startup
  (`Pleroma.Migrators.SearchWindowTokensMigrator`). Search works without the
  index until then, only slowly.

  A RUM index, an index that already has window tokens (for example built
  with `mix pleroma.database search_window_tokens enable` before the upgrade)
  and any other index are kept.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Self-contained on purpose: the code in lib can change after this migration.
  # A full, non-partial GIN index over to_tsvector without window tokens ('W').
  @plain_gin_sql """
  SELECT 1 FROM (
    SELECT pg_get_indexdef(i.indexrelid) AS definition FROM pg_index i
    WHERE i.indexrelid = to_regclass('objects_fts') AND i.indrelid = 'objects'::regclass
  ) d
  WHERE d.definition LIKE '%USING gin %' AND d.definition LIKE '%to_tsvector(%'
    AND d.definition NOT LIKE '%''W''::text%' AND d.definition NOT LIKE '%) WHERE %'
  """

  def up do
    if plain_gin?(repo()), do: execute("DROP INDEX CONCURRENTLY IF EXISTS objects_fts")

    dt = NaiveDateTime.utc_now()

    execute(
      "INSERT INTO data_migrations(name, inserted_at, updated_at) " <>
        "VALUES ('search_window_tokens', '#{dt}', '#{dt}') ON CONFLICT DO NOTHING;"
    )
  end

  # The plain index is not rebuilt here, as that can take hours; search works
  # without it. Rebuild it with `mix pleroma.database search_window_tokens disable`.
  def down do
    execute("DELETE FROM data_migrations WHERE name = 'search_window_tokens';")
  end

  def plain_gin?(repo), do: repo.query!(@plain_gin_sql).rows != []
end
