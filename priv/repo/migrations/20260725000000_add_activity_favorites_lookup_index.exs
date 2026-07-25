# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddActivityFavoritesLookupIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists(
      index(:activities, [:actor, "associated_object_id(data)", "id DESC"],
        name: :activities_favorites_lookup_index,
        where: "data->>'type' = 'Like'",
        concurrently: true
      )
    )
  end
end
