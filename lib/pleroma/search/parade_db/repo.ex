# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.ParadeDB.Repo do
  use Ecto.Repo,
    otp_app: :pleroma,
    adapter: Ecto.Adapters.Postgres,
    migration_timestamps: [type: :naive_datetime_usec]

  @doc """
  Loads the ParadeDB database URL from `PARADEDB_DATABASE_URL`.

  If the env var is not set, falls back to `config :pleroma, Pleroma.Search.ParadeDB, url: ...`.
  """
  def init(_, opts) do
    config = Application.get_env(:pleroma, Pleroma.Search.ParadeDB, [])

    url = System.get_env("PARADEDB_DATABASE_URL") || config[:url]
    url = if is_nil(url), do: nil, else: to_string(url)

    {:ok, Keyword.put(opts, :url, url)}
  end
end
