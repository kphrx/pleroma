# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.BackfillInstancesFromUsers do
  use Ecto.Migration

  # Remote users now create an instances row; add the hosts of existing ones,
  # so the peer list can come from the instances table.
  def up do
    Pleroma.Repo.query!(
      """
      INSERT INTO instances (host, inserted_at, updated_at)
      SELECT DISTINCT host, now(), now()
      FROM (
        SELECT substring(ap_id from '^[A-Za-z][A-Za-z0-9+.-]*://([^/:?#]+)') AS host
        FROM users
        WHERE local = false AND ap_id IS NOT NULL
      ) AS hosts
      WHERE host IS NOT NULL
      ON CONFLICT (host) DO NOTHING
      """,
      [],
      timeout: :infinity
    )
  end

  def down, do: :ok
end
