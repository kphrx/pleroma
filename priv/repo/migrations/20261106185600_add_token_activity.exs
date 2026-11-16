# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddTokenActivity do
  use Ecto.Migration

  def change do
    alter table(:oauth_tokens) do
      add_if_not_exists(:last_active, :naive_datetime_usec)
    end
  end
end
