defmodule Pleroma.Repo.Migrations.AddActivityAssignedAccountIndex do
  use Ecto.Migration

  def up, do: :noop

  def down do
    drop_if_exists(
      index(:activities, ["(data->>'assigned_account')"],
        name: :activities_assigned_account_index
      )
    )
  end
end
