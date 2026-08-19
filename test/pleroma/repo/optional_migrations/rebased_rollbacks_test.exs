# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.OptionalMigrations.RebasedRollbacksTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :pleroma,
      adapter: Ecto.Adapters.Postgres
  end

  @migrations_path "priv/repo/migrations"
  @rollbacks_path "priv/repo/optional_migrations/rebased_rollbacks"

  @expected_versions ~w{
    20210612185407
    20220314220000
    20220819171321
    20220927220033
    20221207235104
  }

  test "only includes Rebased-specific migration versions" do
    rollback_versions = migration_versions(@rollbacks_path)
    pleroma_versions = migration_versions(@migrations_path)

    assert rollback_versions == @expected_versions
    assert MapSet.disjoint?(MapSet.new(rollback_versions), MapSet.new(pleroma_versions))
  end

  test "rolls back Rebased schema without removing Pleroma data" do
    prefix = "rebased_rollbacks_#{Ecto.UUID.generate() |> String.replace("-", "")}"

    repo_config = [
      username: "postgres",
      password: "postgres",
      database: System.get_env("DB_NAME", "pleroma_test"),
      hostname: System.get_env("DB_HOST", "localhost"),
      port: String.to_integer(System.get_env("DB_PORT", "5432")),
      pool_size: 2,
      parameters: [search_path: prefix]
    ]

    {:ok, repo} = MigrationRepo.start_link(repo_config)
    Process.unlink(repo)

    on_exit(fn ->
      query!("DROP SCHEMA IF EXISTS #{prefix} CASCADE")
      MigrationRepo.stop()
    end)

    query!("CREATE SCHEMA #{prefix}")

    create_rebased_schema()

    expected_rollbacks =
      @expected_versions
      |> Enum.reverse()
      |> Enum.map(&String.to_integer/1)

    assert Ecto.Migrator.run(MigrationRepo, @rollbacks_path, :down, all: true) ==
             expected_rollbacks

    assert query!("SELECT version FROM schema_migrations ORDER BY version").rows == [
             [20_220_624_104_914],
             [20_221_029_171_353]
           ]

    assert query!("""
           SELECT column_name
           FROM information_schema.columns
           WHERE table_schema = current_schema() AND table_name = 'users'
           ORDER BY column_name
           """).rows == [["id"]]

    assert query!("SELECT type::text FROM notifications ORDER BY type::text").rows == [["status"]]

    assert query!("""
           SELECT enumlabel
           FROM pg_enum
           JOIN pg_type ON pg_type.oid = enumtypid
           JOIN pg_namespace ON pg_namespace.oid = pg_type.typnamespace
           WHERE typname = 'notification_type' AND nspname = current_schema()
           ORDER BY enumsortorder
           """).rows ==
             Enum.map(
               ~w{follow follow_request mention move pleroma:emoji_reaction pleroma:chat_mention reblog favourite pleroma:report poll status update},
               &[&1]
             )

    assert query!("SELECT to_regclass('objects_events')").rows == [[nil]]

    assert query!("SELECT url, secret, internal FROM webhooks").rows == [
             ["https://example.com/webhook", "preserve-me", false]
           ]
  end

  defp migration_versions(path) do
    path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(fn migration ->
      migration
      |> Path.basename()
      |> String.split("_", parts: 2)
      |> hd()
    end)
    |> Enum.sort()
  end

  defp create_rebased_schema do
    statements = [
      """
      CREATE TYPE notification_type AS ENUM (
        'follow', 'follow_request', 'mention', 'move', 'pleroma:emoji_reaction',
        'pleroma:chat_mention', 'reblog', 'favourite', 'pleroma:report', 'poll',
        'status', 'update', 'pleroma:participation_accepted',
        'pleroma:participation_request', 'pleroma:event_reminder',
        'pleroma:event_update'
      )
      """,
      "CREATE TABLE notifications (id bigserial PRIMARY KEY, type notification_type)",
      """
      INSERT INTO notifications (type) VALUES
        ('status'),
        ('pleroma:participation_accepted'),
        ('pleroma:participation_request'),
        ('pleroma:event_reminder'),
        ('pleroma:event_update')
      """,
      """
      CREATE TABLE users (
        id bigserial PRIMARY KEY,
        accepts_email_list boolean,
        location varchar(255),
        last_move_at timestamp
      )
      """,
      "CREATE TABLE objects (id bigserial PRIMARY KEY, data jsonb)",
      "CREATE INDEX objects_events ON objects ((data->>'type')) WHERE data->>'type' = 'Event'",
      """
      CREATE TABLE webhooks (
        id bigserial PRIMARY KEY,
        url varchar(255) NOT NULL,
        events varchar[] NOT NULL DEFAULT '{}',
        secret varchar(255) NOT NULL DEFAULT '',
        enabled boolean NOT NULL DEFAULT true,
        internal boolean NOT NULL DEFAULT false
      )
      """,
      "CREATE UNIQUE INDEX webhooks_url_index ON webhooks (url)",
      "INSERT INTO webhooks (url, secret) VALUES ('https://example.com/webhook', 'preserve-me')",
      "CREATE TABLE schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0))",
      """
      INSERT INTO schema_migrations (version, inserted_at) VALUES
        (20210612185407, NOW()),
        (20220314220000, NOW()),
        (20220624104914, NOW()),
        (20220819171321, NOW()),
        (20220927220033, NOW()),
        (20221029171353, NOW()),
        (20221207235104, NOW())
      """
    ]

    Enum.each(statements, &query!/1)
  end

  defp query!(statement), do: SQL.query!(MigrationRepo, statement, [])
end
