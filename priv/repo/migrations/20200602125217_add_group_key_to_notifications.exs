defmodule Pleroma.Repo.Migrations.AddGroupKeyToNotifications do
  use Ecto.Migration

  def change do
    alter table(:notifications) do
      add(:group_key, :string)
    end

    create_if_not_exists(
      index(:notifications, [:user_id, :group_key, "id desc nulls last"],
        where: "group_key IS NOT NULL"
      )
    )
  end
end
