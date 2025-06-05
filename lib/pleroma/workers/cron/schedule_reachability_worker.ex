# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.ScheduleReachabilityWorker do
  use Oban.Worker,
    queue: :background,
    max_attempts: 2

  alias Pleroma.Instances
  alias Pleroma.Repo

  @impl true
  def perform(_job) do
    unreachable_servers = Instances.get_unreachable()

    jobs =
      unreachable_servers
      |> Enum.map(fn {domain, _} ->
        Pleroma.Workers.ReachabilityWorker.new(%{"domain" => domain})
      end)

    case Repo.transaction(fn ->
           Enum.each(jobs, &Oban.insert/1)
         end) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
