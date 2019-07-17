defmodule Pleroma.Repo.Migrations.AddForeignKeyActivitiesActorReferencesUsersApid do
  use Ecto.Migration

  def change do
    execute "DELETE FROM activities WHERE activities.actor not in (SELECT ap_id FROM users)"

    alter table :activities do
      modify :actor, references(:users, type: :varchar, column: :ap_id, on_delete: :delete_all)
    end
  end
end
