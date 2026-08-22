defmodule Pleroma.Repo.Migrations.AddLastMoveAtToUsers do
  use Ecto.Migration

  def up, do: :noop

  def down do
    alter table(:users) do
      remove_if_exists(:last_move_at, :naive_datetime)
    end
  end
end
