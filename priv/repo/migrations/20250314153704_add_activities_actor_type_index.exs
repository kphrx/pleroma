defmodule Pleroma.Repo.Migrations.AddActivitiesActorTypeIndex do
  use Ecto.Migration

  def change do
    create(index(:activities, ["actor", "(data ->> 'type'::text)", "id DESC NULLS LAST"]))
  end
end
