defmodule Pleroma.Workers.Cron.ReachabilityPruner do
  use Oban.Worker, queue: :background, max_attempts: 1

  import Ecto.Query
  require Logger

  @reachability_worker "Elixir.Pleroma.Workers.ReachabilityWorker"
  @prune_days 6

  @impl true
  def perform(_job) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@prune_days * 24 * 60 * 60, :second)

    {count, _} =
      from(j in Oban.Job,
        where: j.worker == @reachability_worker and j.inserted_at < ^cutoff
      )
      |> Pleroma.Repo.delete_all()

    if count > 0 do
      Logger.debug(fn -> "Pruned #{count} old ReachabilityWorker jobs." end)
    end

    :ok
  end
end
