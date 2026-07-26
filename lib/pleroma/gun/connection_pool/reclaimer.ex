# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun.ConnectionPool.Reclaimer do
  use GenServer, restart: :temporary

  defp registry, do: Pleroma.Gun.ConnectionPool

  def start_monitor do
    pid =
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          pid
      end

    {pid, Process.monitor(pid)}
  end

  @impl true
  def init(_) do
    {:ok, nil, {:continue, :reclaim}}
  end

  @impl true
  def handle_continue(:reclaim, _) do
    max_connections = Pleroma.Config.get([:connections_pool, :max_connections])

    reclaim_max =
      [:connections_pool, :reclaim_multiplier]
      |> Pleroma.Config.get()
      |> Kernel.*(max_connections)
      |> round
      |> max(1)

    :telemetry.execute([:pleroma, :connection_pool, :reclaim, :start], %{}, %{
      max_connections: max_connections,
      reclaim_max: reclaim_max
    })

    workers =
      Registry.select(
        registry(),
        [
          {{:_, :"$1", {:_, :_}}, [], [:"$1"]}
        ]
      )

    unused_conns = Enum.flat_map(workers, &reclaim_info/1)

    case unused_conns do
      [] ->
        :telemetry.execute(
          [:pleroma, :connection_pool, :reclaim, :stop],
          %{reclaimed_count: 0},
          %{
            max_connections: max_connections
          }
        )

        {:stop, :no_unused_conns, nil}

      unused_conns ->
        reclaimed_count =
          unused_conns
          |> Enum.sort_by(fn {_pid, crf, last_reference} -> {crf, last_reference} end)
          |> Enum.reduce_while(0, fn
            _worker, count when count == reclaim_max ->
              {:halt, count}

            {worker_pid, _crf, _last_reference}, count ->
              if reclaim(worker_pid), do: {:cont, count + 1}, else: {:cont, count}
          end)

        :telemetry.execute(
          [:pleroma, :connection_pool, :reclaim, :stop],
          %{reclaimed_count: reclaimed_count},
          %{max_connections: max_connections}
        )

        {:stop, :normal, nil}
    end
  end

  defp reclaim_info(worker_pid) do
    try do
      case GenServer.call(worker_pid, :reclaim_info) do
        {:idle, crf, last_reference} -> [{worker_pid, crf, last_reference}]
        :in_use -> []
      end
    catch
      :exit, _ -> []
    end
  end

  defp reclaim(worker_pid) do
    try do
      GenServer.call(worker_pid, :reclaim) == :reclaimed
    catch
      :exit, _ -> false
    end
  end
end
