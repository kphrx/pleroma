# Adapted from Rebased
# https://gitlab.com/soapbox-pub/rebased/-/blob/main/priv/repo/migrations/20221207235104_add_events_index.exs

defmodule Pleroma.Repo.Migrations.AddEventsIndex do
  use Ecto.Migration

  def up, do: :noop

  def down do
    drop_if_exists(
      index(:objects, ["(data->>'type')"],
        where: "data->>'type' = 'Event'",
        name: :objects_events
      )
    )
  end
end
