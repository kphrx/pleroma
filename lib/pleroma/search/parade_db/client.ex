# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.ParadeDB.Client do
  @moduledoc false

  @type sql :: String.t()
  @type params :: list()
  @type result :: %{optional(:rows) => list(list())}

  @callback query(sql(), params()) :: {:ok, result()} | {:error, any()}
end

defmodule Pleroma.Search.ParadeDB.Client.Postgres do
  @moduledoc false

  @behaviour Pleroma.Search.ParadeDB.Client

  @impl true
  def query(sql, params \\ []) do
    Ecto.Adapters.SQL.query(Pleroma.Search.ParadeDB.Repo, sql, params)
  end
end
