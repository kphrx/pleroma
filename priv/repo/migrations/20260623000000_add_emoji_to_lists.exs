defmodule Pleroma.Repo.Migrations.AddEmojiToLists do
  use Ecto.Migration

  def change do
    alter table(:lists) do
      add(:emoji, :string)
    end
  end
end
