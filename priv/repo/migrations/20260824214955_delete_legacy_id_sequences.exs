defmodule Pleroma.Repo.Migrations.DeleteLegacyIdSequences do
  use Ecto.Migration

  def change do
    execute("DROP SEQUENCE IF EXISTS activities_id_seq")
    execute("DROP SEQUENCE IF EXISTS chats_id_seq")
    execute("DROP SEQUENCE IF EXISTS users_id_seq")
  end
end
