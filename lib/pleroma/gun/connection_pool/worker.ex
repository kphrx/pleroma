# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun.ConnectionPool.Worker do
  alias Pleroma.Gun
  use GenServer, restart: :temporary

  defp registry, do: Pleroma.Gun.ConnectionPool

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init([key, _uri, _opts, _client_pid] = opts) do
    {:ok, _} = Registry.register(registry(), key, nil)
    {:ok, nil, {:continue, {:connect, opts}}}
  end

  @impl true
  def handle_continue({:connect, [key, uri, opts, client_pid]}, _) do
    with {:ok, conn_pid, protocol, tunnel} <- Gun.Conn.open(uri, opts),
         Process.link(conn_pid) do
      time = :erlang.monotonic_time(:millisecond)

      Registry.unregister(registry(), key)
      {:ok, _} = Registry.register(registry(), key, {conn_pid, tunnel})

      send(client_pid, {:conn_pid, conn_pid})

      {:noreply,
       %{
         key: key,
         timer: nil,
         clients: %{
           client_pid => %{count: 1, monitor: Process.monitor(client_pid), streams: MapSet.new()}
         },
         conn_pid: conn_pid,
         protocol: protocol,
         proxied: Keyword.has_key?(opts, :proxy),
         crf: 1,
         last_reference: time
       }, :hibernate}
    else
      err ->
        {:stop, {:shutdown, err}, nil}
    end
  end

  @impl true
  def handle_call(:checkout, _from, %{protocol: protocol, clients: clients} = state)
      when protocol != :http2 and map_size(clients) > 0 do
    {:reply, :busy, state, :hibernate}
  end

  def handle_call(:checkout, {client_pid, _}, %{key: key, protocol: protocol} = state) do
    time = :erlang.monotonic_time(:millisecond)

    [{_, {conn_pid, _tunnel}}] =
      Registry.lookup(registry(), key) |> Enum.filter(&(elem(&1, 0) == self()))

    state =
      state
      |> cancel_idle_timer()
      |> add_client(client_pid)
      |> Map.put(:crf, crf(time - state.last_reference, state.crf))
      |> Map.put(:last_reference, time)

    :telemetry.execute(
      [:pleroma, :connection_pool, :client, :add],
      %{client_pid: client_pid, clients: Map.keys(state.clients)},
      %{key: state.key, protocol: protocol}
    )

    {:reply, {:ok, conn_pid}, state, :hibernate}
  end

  @impl true
  def handle_call(:remove_client, {client_pid, _}, state) do
    case active_streams(state, client_pid) do
      [] ->
        {:reply, :ok, remove_client(state, client_pid, true), :hibernate}

      streams when state.protocol == :http2 ->
        Enum.each(streams, &(:ok = Gun.cancel(state.conn_pid, &1)))
        {:reply, :ok, remove_client(state, client_pid, true), :hibernate}

      _streams ->
        {:stop, :normal, :ok, state}
    end
  end

  def handle_call({:register_stream, stream}, {client_pid, _}, state) do
    {:reply, :ok, update_stream(state, client_pid, &MapSet.put(&1, stream)), :hibernate}
  end

  def handle_call({:finish_stream, stream}, {client_pid, _}, state) do
    {:reply, :ok, update_stream(state, client_pid, &MapSet.delete(&1, stream)), :hibernate}
  end

  def handle_call({:release_stream, stream}, {client_pid, _}, state) do
    state = update_stream(state, client_pid, &MapSet.delete(&1, stream))
    {:reply, :ok, remove_client(state, client_pid, true), :hibernate}
  end

  def handle_call({:cancel_stream, stream}, {client_pid, _}, %{protocol: :http2} = state) do
    :ok = Gun.cancel(state.conn_pid, stream)
    state = update_stream(state, client_pid, &MapSet.delete(&1, stream))
    {:reply, :ok, remove_client(state, client_pid, true), :hibernate}
  end

  def handle_call({:cancel_stream, _stream}, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(:reclaim_info, _from, %{clients: clients} = state)
      when map_size(clients) == 0 do
    {:reply, {:idle, state.crf, state.last_reference}, state, :hibernate}
  end

  def handle_call(:reclaim_info, _from, state) do
    {:reply, :in_use, state, :hibernate}
  end

  def handle_call(:reclaim, _from, %{clients: clients} = state) when map_size(clients) == 0 do
    {:stop, :normal, :reclaimed, state}
  end

  def handle_call(:reclaim, _from, state) do
    {:reply, :in_use, state, :hibernate}
  end

  @impl true
  def handle_info({:idle_close, token}, %{timer: {_timer_ref, token}, clients: clients} = state)
      when map_size(clients) == 0 do
    # Gun monitors the owner process, and will close the connection automatically.
    {:stop, :normal, state}
  end

  def handle_info({:idle_close, _token}, state), do: {:noreply, state, :hibernate}

  @impl true
  def handle_info({:gun_up, _pid, protocol}, state) do
    {:noreply, %{state | protocol: protocol}, :hibernate}
  end

  @impl true
  def handle_info({:gun_error, conn_pid, stream, _reason}, %{conn_pid: conn_pid} = state) do
    {:noreply, delete_stream(state, stream), :hibernate}
  end

  @impl true
  def handle_info({:gun_down, _pid, _protocol, _reason, _streams}, %{proxied: true} = state) do
    {:stop, :normal, state}
  end

  # Gracefully shutdown if the connection got closed without any streams left.
  @impl true
  def handle_info({:gun_down, _pid, _protocol, _reason, []}, state) do
    {:stop, :normal, state}
  end

  # Otherwise, wait for retry.
  @impl true
  def handle_info({:gun_down, _pid, _protocol, _reason, _killed_streams}, state) do
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case state.clients[pid] do
      %{monitor: ^ref} ->
        :telemetry.execute(
          [:pleroma, :connection_pool, :client, :dead],
          %{client_pid: pid, reason: reason},
          %{key: state.key}
        )

        handle_dead_client(state, pid)

      _ ->
        {:noreply, state, :hibernate}
    end
  end

  defp add_client(state, client_pid) do
    update_in(state.clients, fn clients ->
      case clients[client_pid] do
        nil ->
          Map.put(clients, client_pid, %{
            count: 1,
            monitor: Process.monitor(client_pid),
            streams: MapSet.new()
          })

        client ->
          Map.put(clients, client_pid, %{client | count: client.count + 1})
      end
    end)
  end

  defp handle_dead_client(state, client_pid) do
    streams = active_streams(state, client_pid)

    cond do
      streams == [] ->
        {:noreply, remove_client(state, client_pid, false, true), :hibernate}

      state.protocol == :http2 ->
        Enum.each(streams, &(:ok = Gun.cancel(state.conn_pid, &1)))
        {:noreply, remove_client(state, client_pid, false, true), :hibernate}

      true ->
        {:stop, :normal, state}
    end
  end

  defp active_streams(state, client_pid) do
    case state.clients[client_pid] do
      %{streams: streams} -> MapSet.to_list(streams)
      nil -> []
    end
  end

  defp update_stream(state, client_pid, update) do
    update_in(state.clients, fn clients ->
      case clients[client_pid] do
        nil -> clients
        client -> Map.put(clients, client_pid, %{client | streams: update.(client.streams)})
      end
    end)
  end

  defp delete_stream(state, stream) do
    update_in(state.clients, fn clients ->
      Map.new(clients, fn {pid, client} ->
        {pid, %{client | streams: MapSet.delete(client.streams, stream)}}
      end)
    end)
  end

  defp remove_client(state, client_pid, demonitor, all \\ false) do
    case state.clients[client_pid] do
      nil ->
        state

      %{count: count} = client when count > 1 and not all ->
        put_in(state.clients[client_pid], %{client | count: count - 1})

      client ->
        if demonitor, do: Process.demonitor(client.monitor, [:flush])
        state = update_in(state.clients, &Map.delete(&1, client_pid))

        if map_size(state.clients) == 0, do: schedule_idle_close(state), else: state
    end
  end

  defp cancel_idle_timer(%{timer: nil} = state), do: state

  defp cancel_idle_timer(%{timer: {timer_ref, _token}} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer: nil}
  end

  defp schedule_idle_close(state) do
    max_idle = Pleroma.Config.get([:connections_pool, :max_idle_time], 30_000)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:idle_close, token}, max_idle)
    %{state | timer: {timer_ref, token}}
  end

  # LRFU policy: https://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.55.1478
  defp crf(time_delta, prev_crf) do
    1 + :math.pow(0.5, 0.0001 * time_delta) * prev_crf
  end
end
