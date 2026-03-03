# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.ParadeDBIntegrationTest do
  use Pleroma.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 180_000

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Search.ParadeDB
  alias Pleroma.Web.CommonAPI

  @image "paradedb/paradedb:latest"
  @db_user "postgres"
  @db_password "postgres"
  @db_name "paradedb"
  @docker_startup_timeout_ms 60_000

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  setup_all do
    with :ok <- ensure_docker_available() do
      container = "pleroma-paradedb-it-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = docker(["rm", "-f", container])
      end)

      {id, 0} =
        docker([
          "run",
          "--rm",
          "--name",
          container,
          "-e",
          "POSTGRES_USER=#{@db_user}",
          "-e",
          "POSTGRES_PASSWORD=#{@db_password}",
          "-e",
          "POSTGRES_DB=#{@db_name}",
          "-p",
          "5432",
          "-d",
          @image
        ])

      container_id = String.trim(id)

      host_port =
        container
        |> wait_for_port!(@docker_startup_timeout_ms)

      wait_for_pg_ready!(container, @docker_startup_timeout_ms)
      wait_for_tcp_ready!(host_port, @docker_startup_timeout_ms)

      url = "postgres://#{@db_user}:#{@db_password}@127.0.0.1:#{host_port}/#{@db_name}"

      prev_env = System.get_env("PARADEDB_DATABASE_URL")
      System.put_env("PARADEDB_DATABASE_URL", url)

      on_exit(fn ->
        if is_nil(prev_env) do
          System.delete_env("PARADEDB_DATABASE_URL")
        else
          System.put_env("PARADEDB_DATABASE_URL", prev_env)
        end
      end)

      {:ok, _pid} = start_supervised({Pleroma.Search.ParadeDB.Repo, pool_size: 1})

      table = "pleroma_search_documents_it_#{System.unique_integer([:positive])}"
      Pleroma.Config.put([Pleroma.Search.ParadeDB, :table], table)

      {:ok,
       %{
         container: container,
         container_id: container_id,
         url: url,
         table: table
       }}
    end
  end

  test "indexes and searches against real ParadeDB" do
    :ok = ParadeDB.drop_index()
    assert :ok = ParadeDB.create_index()

    user = insert(:user)

    {:ok, a1} =
      CommonAPI.post(user, %{status: "paradedb integration first", visibility: "public"})

    :timer.sleep(1100)

    {:ok, a2} =
      CommonAPI.post(user, %{status: "paradedb integration second", visibility: "public"})

    {:ok, private} =
      CommonAPI.post(user, %{status: "paradedb integration private", visibility: "private"})

    a1 = Activity.get_by_id_with_object(a1.id)
    a2 = Activity.get_by_id_with_object(a2.id)
    private = Activity.get_by_id_with_object(private.id)

    assert :ok = ParadeDB.add_to_index(a1)
    assert :ok = ParadeDB.add_to_index(a2)
    assert :ok = ParadeDB.add_to_index(private)

    results = ParadeDB.search(nil, "paradedb integration", limit: 40, offset: 0)
    ids = Enum.map(results, & &1.id)

    assert a1.id in ids
    assert a2.id in ids
    refute private.id in ids
    assert List.first(ids) == a2.id

    # Removing an object should remove it from the ParadeDB index.
    assert :ok = ParadeDB.remove_from_index(a2.object)

    results_after_delete = ParadeDB.search(nil, "paradedb integration", limit: 40, offset: 0)
    ids_after_delete = Enum.map(results_after_delete, & &1.id)

    assert a1.id in ids_after_delete
    refute a2.id in ids_after_delete
  end

  defp ensure_docker_available do
    if is_nil(System.find_executable("docker")) do
      {:skip, "Docker not installed"}
    else
      case docker(["info"]) do
        {_out, 0} -> :ok
        {out, _} -> {:skip, "Docker not available: #{String.trim(out)}"}
      end
    end
  end

  defp wait_for_port!(container, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait = fn wait ->
      case docker(["port", container, "5432/tcp"]) do
        {out, 0} when byte_size(out) > 0 ->
          out
          |> String.split("\n", trim: true)
          |> List.first()
          |> parse_host_port!()

        _ ->
          if System.monotonic_time(:millisecond) > deadline do
            raise "Timed out waiting for docker port mapping"
          else
            :timer.sleep(250)
            wait.(wait)
          end
      end
    end

    wait.(wait)
  end

  defp parse_host_port!(mapping) do
    mapping
    |> String.trim()
    |> String.split(":")
    |> List.last()
    |> String.to_integer()
  end

  defp wait_for_pg_ready!(container, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait = fn wait ->
      case docker([
             "exec",
             container,
             "pg_isready",
             "-U",
             @db_user,
             "-d",
             @db_name
           ]) do
        {_out, 0} ->
          :ok

        _ ->
          if System.monotonic_time(:millisecond) > deadline do
            raise "Timed out waiting for ParadeDB Postgres to become ready"
          else
            :timer.sleep(250)
            wait.(wait)
          end
      end
    end

    wait.(wait)
  end

  defp wait_for_tcp_ready!(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait = fn wait ->
      case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          :ok

        {:error, _} ->
          if System.monotonic_time(:millisecond) > deadline do
            raise "Timed out waiting for TCP port #{port} to accept connections"
          else
            :timer.sleep(250)
            wait.(wait)
          end
      end
    end

    wait.(wait)
  end

  defp docker(args) do
    System.cmd("docker", args, stderr_to_stdout: true)
  end
end
