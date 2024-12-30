defmodule Pleroma.Repo.Migrations.AddInternalToWebhooks do
  use Ecto.Migration

  def up, do: :noop

  def down do
    alter table(:webhooks) do
      remove_if_exists(:internal, :boolean)
    end
  end
end
