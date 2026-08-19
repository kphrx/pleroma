defmodule Pleroma.Repo.Migrations.AddLocationToUsers do
  use Ecto.Migration

  def up, do: :noop

  def down do
    alter table(:users) do
      remove_if_exists(:location, :string)
    end
  end
end
