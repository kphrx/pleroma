# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun.ConnectionPool do
  @registry __MODULE__
  @locks Module.concat(__MODULE__, Locks)

  alias Pleroma.Gun.ConnectionPool.WorkerSupervisor

  @connection_option_keys [
    :http_opts,
    :http2_opts,
    :protocols,
    :proxy,
    :proxy_auth,
    :proxy_tls_opts,
    :retry,
    :retry_timeout,
    :socks_opts,
    :tcp_opts,
    :tls_opts,
    :transport,
    :ws_opts
  ]

  def children do
    [
      {Registry, keys: :duplicate, name: @registry},
      {Registry, keys: :unique, name: @locks},
      Pleroma.Gun.ConnectionPool.WorkerSupervisor
    ]
  end

  @spec get_conn(URI.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get_conn(uri, opts) do
    key = connection_key(uri, opts)

    case checkout_existing(Registry.lookup(@registry, key)) do
      {:ok, gun_pid} ->
        {:ok, gun_pid}

      :not_available ->
        provision_or_wait(key, uri, opts)
    end
  end

  defp checkout_existing([]), do: :not_available

  defp checkout_existing([{_worker_pid, nil} | workers]), do: checkout_existing(workers)

  defp checkout_existing([{worker_pid, _value} | workers]) do
    case checkout_worker(worker_pid) do
      {:ok, gun_pid} -> {:ok, gun_pid}
      _ -> checkout_existing(workers)
    end
  end

  defp provision_or_wait(key, uri, opts) do
    result = with_route_lock(key, fn -> provision(key, uri, opts) end)

    case result do
      {:ok, gun_pid} ->
        {:ok, gun_pid}

      {:new, worker_pid} ->
        get_gun_pid_from_worker(worker_pid)

      {:wait, worker_pid} ->
        case checkout_worker(worker_pid, :infinity) do
          {:ok, gun_pid} -> {:ok, gun_pid}
          :busy -> get_conn(uri, opts)
          error -> error
        end

      error ->
        error
    end
  end

  defp provision(key, uri, opts) do
    workers = Registry.lookup(@registry, key)

    case checkout_existing(workers) do
      {:ok, gun_pid} ->
        {:ok, gun_pid}

      :not_available ->
        case Enum.find(workers, fn {_worker_pid, value} -> is_nil(value) end) do
          {worker_pid, nil} -> {:wait, worker_pid}
          nil -> start_worker(key, uri, opts)
        end
    end
  end

  defp with_route_lock(key, function) do
    case Registry.register(@locks, key, nil) do
      {:ok, _} ->
        try do
          function.()
        after
          Registry.unregister(@locks, key)
        end

      {:error, {:already_registered, _owner}} ->
        Process.sleep(1)
        with_route_lock(key, function)
    end
  end

  defp start_worker(key, uri, opts) do
    # :gun.set_owner fails in :connected state, so the worker opens the connection itself.
    case WorkerSupervisor.start_worker([key, uri, opts, self()]) do
      {:ok, worker_pid} -> {:new, worker_pid}
      error -> error
    end
  end

  defp checkout_worker(worker_pid, timeout \\ 5_000) do
    try do
      GenServer.call(worker_pid, :checkout, timeout)
    catch
      :exit, reason -> {:error, {:connection_worker_exit, reason}}
    end
  end

  defp get_gun_pid_from_worker(worker_pid) do
    # GenServer.call will block the process for timeout length if
    # the server crashes on startup (which will happen if gun fails to connect)
    # so instead we use cast + monitor

    ref = Process.monitor(worker_pid)

    receive do
      {:conn_pid, pid} ->
        Process.demonitor(ref)
        {:ok, pid}

      {:DOWN, ^ref, :process, ^worker_pid, reason} ->
        case reason do
          {:shutdown, {:error, _} = error} -> error
          {:shutdown, error} -> {:error, error}
          _ -> {:error, reason}
        end
    end
  end

  @spec release_conn(pid()) :: :ok
  def release_conn(conn_pid) do
    # :ets.fun2ms(fn {_, {worker_pid, {gun_pid, _tunnel}}} when gun_pid == conn_pid ->
    #    worker_pid end)
    query_result =
      Registry.select(@registry, [
        {{:_, :"$1", {:"$2", :_}}, [{:==, :"$2", conn_pid}], [:"$1"]}
      ])

    case query_result do
      [worker_pid] ->
        try do
          GenServer.call(worker_pid, :remove_client)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  @spec discard_conn(pid()) :: :ok
  def discard_conn(conn_pid) do
    case worker_for_conn(conn_pid) do
      nil ->
        :ok

      worker_pid ->
        DynamicSupervisor.terminate_child(WorkerSupervisor, worker_pid)
    end
  end

  @spec cancel_stream(pid(), reference() | [reference()]) :: :ok
  def cancel_stream(conn_pid, stream) do
    case worker_for_conn(conn_pid) do
      nil ->
        Pleroma.Gun.cancel(conn_pid, stream)

      worker_pid ->
        try do
          GenServer.call(worker_pid, {:cancel_stream, stream})
        catch
          :exit, _ -> :ok
        end
    end
  end

  @spec register_stream(pid(), reference() | [reference()]) :: :ok
  def register_stream(conn_pid, stream) do
    call_worker(conn_pid, {:register_stream, stream})
  end

  @spec finish_stream(pid(), reference() | [reference()]) :: :ok
  def finish_stream(conn_pid, stream) do
    call_worker(conn_pid, {:finish_stream, stream})
  end

  @spec release_stream(pid(), reference() | [reference()]) :: :ok
  def release_stream(conn_pid, stream) do
    call_worker(conn_pid, {:release_stream, stream})
  end

  @spec tunnel_ref(pid()) :: reference() | :forward_proxy | nil
  def tunnel_ref(conn_pid) do
    case Registry.select(@registry, [
           {{:_, :_, {:"$1", :"$2"}}, [{:==, :"$1", conn_pid}], [:"$2"]}
         ]) do
      [tunnel] -> tunnel
      [] -> nil
    end
  end

  defp worker_for_conn(conn_pid) do
    case Registry.select(@registry, [
           {{:_, :"$1", {:"$2", :_}}, [{:==, :"$2", conn_pid}], [:"$1"]}
         ]) do
      [worker_pid] -> worker_pid
      [] -> nil
    end
  end

  defp call_worker(conn_pid, message) do
    case worker_for_conn(conn_pid) do
      nil ->
        :ok

      worker_pid ->
        try do
          GenServer.call(worker_pid, message)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp connection_key(uri, opts) do
    origin = {
      String.downcase(uri.scheme),
      String.downcase(uri.host),
      uri.port
    }

    profile =
      opts
      |> Map.new()
      |> Map.take(@connection_option_keys)
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    fingerprint = Base.encode16(profile, case: :lower)
    Enum.join(Tuple.to_list(origin) ++ [fingerprint], ":")
  end
end
