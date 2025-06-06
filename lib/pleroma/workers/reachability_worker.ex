# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReachabilityWorker do
  use Oban.Worker,
    queue: :background,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled]]

  alias Pleroma.HTTP
  alias Pleroma.Instances

  @impl true
  def perform(%Oban.Job{args: %{"domain" => domain}}) do
    case HTTP.get("https://#{domain}/") do
      {:ok, %{status: status}} when status in 200..299 ->
        Instances.set_reachable("https://#{domain}")
        :ok

      {:ok, %{status: _status}} ->
        {:error, :unreachable}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def timeout(_job), do: :timer.seconds(5)
end
