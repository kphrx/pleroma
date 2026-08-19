# Adapted from Rebased
# https://gitlab.com/soapbox-pub/rebased/-/blob/main/priv/repo/migrations/20210612185407_add_email_list_field_to_users.exs

defmodule Pleroma.Repo.Migrations.AddEmailListFieldToUsers do
  use Ecto.Migration

  def up, do: :noop

  def down do
    alter table(:users) do
      remove_if_exists(:accepts_email_list, :boolean)
    end
  end
end
