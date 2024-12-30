defmodule Pleroma.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def up, do: :noop

  def down do
    drop_if_exists(unique_index(:webhooks, [:url]))
    drop_if_exists(table(:webhooks))
  end
end
