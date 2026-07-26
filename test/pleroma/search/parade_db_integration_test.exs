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

  @image System.get_env(
           "PARADEDB_TEST_IMAGE",
           "paradedb/paradedb:0.24.3-pg15@sha256:997d62f6c2605becb7c45878af3f8c8c698f355006b675b3ce212d4eb2d14f2e"
         )
  @db_user "postgres"
  @db_password "postgres"
  @db_name "paradedb"
  @docker_startup_timeout_ms 60_000

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  setup_all do
    case System.get_env("PARADEDB_TEST_URL") do
      nil -> setup_docker_paradedb()
      url -> setup_external_paradedb(url)
    end
  end

  defp setup_docker_paradedb do
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
          "127.0.0.1::5432",
          "-d",
          @image
        ])

      container_id = String.trim(id)

      host_port =
        container
        |> wait_for_port!(@docker_startup_timeout_ms)

      wait_for_pg_ready!(container, @docker_startup_timeout_ms)

      url = "postgres://#{@db_user}:#{@db_password}@127.0.0.1:#{host_port}/#{@db_name}"
      setup_repo(url, %{container: container, container_id: container_id})
    end
  end

  defp setup_external_paradedb(url) do
    uri = URI.parse(url)
    wait_for_tcp_ready!(uri.host, uri.port || 5432, @docker_startup_timeout_ms)
    setup_repo(url, %{})
  end

  defp setup_repo(url, context) do
    prev_env = System.get_env("PARADEDB_DATABASE_URL")
    System.put_env("PARADEDB_DATABASE_URL", url)

    on_exit(fn ->
      if is_nil(prev_env) do
        System.delete_env("PARADEDB_DATABASE_URL")
      else
        System.put_env("PARADEDB_DATABASE_URL", prev_env)
      end
    end)

    {:ok, _pid} = start_supervised({Pleroma.Search.ParadeDB.Repo, pool_size: 5})
    wait_for_repo_ready!(@docker_startup_timeout_ms)

    previous_table = Pleroma.Config.get([Pleroma.Search.ParadeDB, :table], nil)
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    table = "pleroma_search_documents_it_#{suffix}"
    Pleroma.Config.put([Pleroma.Search.ParadeDB, :table], table)

    on_exit(fn ->
      if is_nil(previous_table) do
        Pleroma.Config.delete([Pleroma.Search.ParadeDB, :table])
      else
        Pleroma.Config.put([Pleroma.Search.ParadeDB, :table], previous_table)
      end
    end)

    {:ok, Map.merge(context, %{url: url, table: table})}
  end

  test "indexes and searches against real ParadeDB", %{table: table} do
    on_exit(fn ->
      _ =
        Ecto.Adapters.SQL.query(
          Pleroma.Search.ParadeDB.Repo,
          "DROP TABLE IF EXISTS #{table}"
        )
    end)

    :ok = ParadeDB.drop_index()
    assert :ok = ParadeDB.create_index()

    assert {:ok, %{rows: [["0.24.3"]]}} =
             Ecto.Adapters.SQL.query(
               Pleroma.Search.ParadeDB.Repo,
               "SELECT extversion FROM pg_extension WHERE extname = 'pg_search'"
             )

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

    a1 = %{
      a1
      | object: %{
          a1.object
          | data:
              Map.merge(a1.object.data, %{
                "summary" => "paradedb subject phrase",
                "attachment" => [
                  %{
                    "name" => "remote-image.jpg",
                    "summary" => "paradedb attachment description"
                  }
                ]
              })
        }
    }

    assert :ok = ParadeDB.add_to_index(a1)
    assert :ok = ParadeDB.add_to_index(a2)
    assert :ok = ParadeDB.add_to_index(private)

    results = ParadeDB.search(nil, "paradedb integration", limit: 40, offset: 0)
    ids = Enum.map(results, & &1.id)

    assert a1.id in ids
    assert a2.id in ids
    refute private.id in ids
    assert List.first(ids) == a2.id

    assert Enum.any?(ParadeDB.search(nil, "subject phrase"), &(&1.id == a1.id))
    assert Enum.any?(ParadeDB.search(nil, "attachment description"), &(&1.id == a1.id))

    previous_fuzzy_distance = Pleroma.Config.get([Pleroma.Search.ParadeDB, :fuzzy_distance], 0)
    Pleroma.Config.put([Pleroma.Search.ParadeDB, :fuzzy_distance], 1)

    on_exit(fn ->
      Pleroma.Config.put([Pleroma.Search.ParadeDB, :fuzzy_distance], previous_fuzzy_distance)
    end)

    fuzzy_results = ParadeDB.search(nil, "paradedb integraion", limit: 40, offset: 0)
    fuzzy_ids = Enum.map(fuzzy_results, & &1.id)

    assert a1.id in fuzzy_ids
    assert a2.id in fuzzy_ids
    refute private.id in fuzzy_ids

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

  defp wait_for_tcp_ready!(host, port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait = fn wait ->
      case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 500) do
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

  defp wait_for_repo_ready!(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait = fn wait ->
      case Ecto.Adapters.SQL.query(Pleroma.Search.ParadeDB.Repo, "SELECT 1") do
        {:ok, _} ->
          :ok

        _ ->
          if System.monotonic_time(:millisecond) > deadline do
            raise "Timed out waiting for ParadeDB Repo"
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
