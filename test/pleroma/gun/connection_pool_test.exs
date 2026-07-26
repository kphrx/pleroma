# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun.ConnectionPoolTest do
  use Pleroma.DataCase

  import Mox
  import ExUnit.CaptureLog
  alias Pleroma.Gun.ConnectionPool

  defp gun_mock(_) do
    Pleroma.GunMock
    |> stub(:open, fn _, _, _ -> Task.start_link(fn -> Process.sleep(:infinity) end) end)
    |> stub(:await_up, fn _, _ -> {:ok, :http} end)
    |> stub(:connect, fn _, _ -> make_ref() end)
    |> stub(:await, fn _, _ -> {:response, :fin, 200, []} end)
    |> stub(:await_tunnel_up, fn _, _, _ -> {:ok, :http2} end)
    |> stub(:set_owner, fn _, _ -> :ok end)

    :ok
  end

  setup :gun_mock

  test "opens sibling HTTP/1 connections while an existing connection is in use" do
    uri = URI.parse("http://www.korean-books.com.kp/document.pdf")

    assert {:ok, first} = ConnectionPool.get_conn(uri, [])
    assert {:ok, second} = ConnectionPool.get_conn(uri, [])
    assert first != second

    assert :ok = ConnectionPool.release_conn(first)
    assert :ok = ConnectionPool.release_conn(second)
  end

  test "multiplexes concurrent HTTP/2 leases on one connection" do
    stub(Pleroma.GunMock, :await_up, fn _, _ -> {:ok, :http2} end)
    uri = URI.parse("https://h2.example/inbox")

    assert {:ok, conn} = ConnectionPool.get_conn(uri, [])
    assert {:ok, ^conn} = ConnectionPool.get_conn(uri, [])

    assert :ok = ConnectionPool.release_conn(conn)
    assert :ok = ConnectionPool.release_conn(conn)
    assert Process.alive?(conn)
  end

  test "does not share connections across direct and authenticated proxy routes" do
    uri = URI.parse("https://routes.example/inbox")

    assert {:ok, direct} = ConnectionPool.get_conn(uri, [])

    assert {:ok, proxied} =
             ConnectionPool.get_conn(uri,
               proxy: {~c"proxy.example", 8080},
               proxy_auth: {"alice", "secret"}
             )

    assert {:ok, other_credentials} =
             ConnectionPool.get_conn(uri,
               proxy: {~c"proxy.example", 8080},
               proxy_auth: {"bob", "different-secret"}
             )

    assert Enum.uniq([direct, proxied, other_credentials]) ==
             [direct, proxied, other_credentials]

    registry_dump = inspect(Registry.select(ConnectionPool, [{{:"$1", :_, :_}, [], [:"$1"]}]))
    refute registry_dump =~ "secret"

    Enum.each([direct, proxied, other_credentials], &ConnectionPool.release_conn/1)
  end

  test "coalesces concurrent cold HTTP/2 checkouts behind one connection" do
    test_pid = self()

    stub(Pleroma.GunMock, :await_up, fn _, _ ->
      send(test_pid, {:awaiting_connection, self()})

      receive do
        :continue -> {:ok, :http2}
      end
    end)

    uri = URI.parse("https://cold-h2.example/inbox")

    tasks =
      for _ <- 1..10 do
        Task.async(fn -> ConnectionPool.get_conn(uri, []) end)
      end

    assert_receive {:awaiting_connection, worker_pid}
    refute_receive {:awaiting_connection, _other_worker}, 50
    send(worker_pid, :continue)

    assert [{:ok, conn}] = tasks |> Enum.map(&Task.await/1) |> Enum.uniq()
    assert Process.alive?(conn)
  end

  test "shares a cold connection failure with concurrent waiters" do
    test_pid = self()

    stub(Pleroma.GunMock, :open, fn _, _, _ ->
      send(test_pid, {:opening_connection, self()})

      receive do
        :fail -> {:error, :econnrefused}
      end
    end)

    uri = URI.parse("https://unreachable.example/inbox")

    tasks =
      for _ <- 1..10 do
        Task.async(fn -> ConnectionPool.get_conn(uri, []) end)
      end

    assert_receive {:opening_connection, worker_pid}
    refute_receive {:opening_connection, _other_worker}, 50
    send(worker_pid, :fail)

    assert Enum.all?(tasks, fn task -> match?({:error, _reason}, Task.await(task)) end)
    refute_receive {:opening_connection, _other_worker}, 50
  end

  test "bounds many-host workloads and closes released idle workers" do
    clear_config([:connections_pool, :max_connections]) do
      clear_config([:connections_pool, :max_connections], 25)
      clear_config([:connections_pool, :max_idle_time], 5)
      restart_worker_supervisor()

      on_exit(&restart_worker_supervisor/0)
    end

    connections =
      Enum.map(1..25, fn host_number ->
        uri = URI.parse("https://host-#{host_number}.example/inbox")
        assert {:ok, conn} = ConnectionPool.get_conn(uri, [])
        conn
      end)

    assert DynamicSupervisor.count_children(Pleroma.Gun.ConnectionPool.WorkerSupervisor).active ==
             25

    assert {:error, :pool_full} =
             ConnectionPool.get_conn(URI.parse("https://overflow.example/inbox"), [])

    Enum.each(connections, &ConnectionPool.release_conn/1)

    assert eventually(fn ->
             DynamicSupervisor.count_children(Pleroma.Gun.ConnectionPool.WorkerSupervisor).active ==
               0
           end)
  end

  test "does not reclaim a worker that became active after idle selection" do
    uri = URI.parse("https://reclaim-race.example/inbox")

    assert {:ok, conn} = ConnectionPool.get_conn(uri, [])
    assert :ok = ConnectionPool.release_conn(conn)
    worker = worker_for_conn(conn)

    assert {:idle, _crf, _last_reference} = GenServer.call(worker, :reclaim_info)
    assert {:ok, ^conn} = ConnectionPool.get_conn(uri, [])
    assert :in_use = GenServer.call(worker, :reclaim)
    assert Process.alive?(worker)

    assert :ok = ConnectionPool.release_conn(conn)
  end

  test "cancels one HTTP/2 stream without discarding the connection" do
    stub(Pleroma.GunMock, :await_up, fn _, _ -> {:ok, :http2} end)
    uri = URI.parse("https://cancel-h2.example/inbox")
    stream = make_ref()

    expect(Pleroma.GunMock, :cancel, fn conn, ^stream when is_pid(conn) -> :ok end)

    assert {:ok, conn} = ConnectionPool.get_conn(uri, [])
    assert :ok = ConnectionPool.register_stream(conn, stream)
    assert :ok = ConnectionPool.cancel_stream(conn, stream)
    assert {:ok, ^conn} = ConnectionPool.get_conn(uri, [])
    assert :ok = ConnectionPool.release_conn(conn)
  end

  test "ignores a stale Gun error after cancelling an HTTP/2 stream" do
    stub(Pleroma.GunMock, :await_up, fn _, _ -> {:ok, :http2} end)
    uri = URI.parse("https://stale-cancel-h2.example/inbox")
    stream = make_ref()

    expect(Pleroma.GunMock, :cancel, fn conn, ^stream when is_pid(conn) -> :ok end)

    assert {:ok, conn} = ConnectionPool.get_conn(uri, [])
    worker = worker_for_conn(conn)
    assert :ok = ConnectionPool.register_stream(conn, stream)
    assert :ok = ConnectionPool.cancel_stream(conn, stream)

    send(worker, {:gun_error, conn, stream, {:badstate, "The stream cannot be found."}})
    assert %{clients: %{}} = :sys.get_state(worker)
    assert Process.alive?(worker)

    assert {:ok, ^conn} = ConnectionPool.get_conn(uri, [])
    assert :ok = ConnectionPool.release_conn(conn)
  end

  test "stops an HTTP/1 worker when a client dies with an active stream" do
    uri = URI.parse("http://dead-stream.example/media")
    parent = self()

    client =
      spawn(fn ->
        {:ok, conn} = ConnectionPool.get_conn(uri, [])
        :ok = ConnectionPool.register_stream(conn, make_ref())
        send(parent, {:active_stream, conn})
        Process.sleep(:infinity)
      end)

    assert_receive {:active_stream, conn}
    worker = worker_for_conn(conn)
    Process.exit(client, :kill)

    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "connection limit is respected with concurrent requests" do
    clear_config([:connections_pool, :max_connections]) do
      clear_config([:connections_pool, :max_connections], 1)
      # The supervisor needs a reboot to apply the new config setting
      restart_worker_supervisor()

      on_exit(fn ->
        restart_worker_supervisor()
      end)
    end

    capture_log(fn ->
      Enum.map(
        [
          "https://ninenines.eu/",
          "https://youtu.be/PFGwMiDJKNY"
        ],
        fn uri ->
          uri = URI.parse(uri)
          task_parent = self()

          Task.start_link(fn ->
            result = ConnectionPool.get_conn(uri, [])
            # Sleep so that we don't end up with a situation,
            # where request from the second process gets processed
            # only after the first process already released the connection
            Process.sleep(50)

            case result do
              {:ok, pid} ->
                ConnectionPool.release_conn(pid)

              _ ->
                nil
            end

            send(task_parent, result)
          end)
        end
      )

      [{:error, :pool_full}, {:ok, _pid}] =
        for _ <- 1..2 do
          receive do
            result -> result
          end
        end
        |> Enum.sort()
    end)
  end

  defp restart_worker_supervisor do
    supervisor = Process.whereis(Pleroma.Gun.ConnectionPool.WorkerSupervisor)
    monitor = Process.monitor(supervisor)
    Process.exit(supervisor, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :killed}

    assert eventually(fn ->
             case Process.whereis(Pleroma.Gun.ConnectionPool.WorkerSupervisor) do
               pid when is_pid(pid) -> pid != supervisor and Process.alive?(pid)
               nil -> false
             end
           end)
  end

  defp worker_for_conn(conn) do
    [worker] =
      Registry.select(ConnectionPool, [
        {{:_, :"$1", {:"$2", :_}}, [{:==, :"$2", conn}], [:"$1"]}
      ])

    worker
  end

  defp eventually(predicate, attempts \\ 50)

  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
