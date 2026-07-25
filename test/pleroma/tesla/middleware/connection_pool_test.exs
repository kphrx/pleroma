# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Tesla.Middleware.ConnectionPoolTest do
  use Pleroma.DataCase

  import Mox

  alias Pleroma.Tesla.Middleware.ConnectionPool

  defmodule FailingAdapter do
    @behaviour Tesla.Adapter

    @impl Tesla.Adapter
    def call(_env, _opts), do: {:error, :request_failed}
  end

  defmodule EmptyAdapter do
    @behaviour Tesla.Adapter

    @impl Tesla.Adapter
    def call(env, _opts), do: {:ok, %{env | status: 204, body: ""}}
  end

  test "discards the connection when the adapter cannot finish a request" do
    test_pid = self()

    stub(Pleroma.GunMock, :open, fn _, _, _ ->
      {:ok, conn} = Task.start_link(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:gun_conn, conn})
      {:ok, conn}
    end)

    stub(Pleroma.GunMock, :await_up, fn _, _ -> {:ok, :http} end)

    client = Tesla.client([ConnectionPool], FailingAdapter)

    assert {:error, :request_failed} =
             Tesla.get(client, "http://discard.example/", opts: [adapter: []])

    assert_receive {:gun_conn, conn}

    assert eventually(fn -> not Process.alive?(conn) end)
  end

  test "releases a chunks lease when the response has no stream" do
    clear_config([:connections_pool, :max_idle_time], 5)
    test_pid = self()

    stub(Pleroma.GunMock, :open, fn _, _, _ ->
      {:ok, conn} = Task.start_link(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:gun_conn, conn})
      {:ok, conn}
    end)

    stub(Pleroma.GunMock, :await_up, fn _, _ -> {:ok, :http} end)

    client = Tesla.client([ConnectionPool], EmptyAdapter)

    assert {:ok, %Tesla.Env{status: 204, body: ""}} =
             Tesla.get(client, "http://empty-chunks.example/",
               opts: [adapter: [body_as: :chunks]]
             )

    assert_receive {:gun_conn, conn}
    worker = worker_for_conn(conn)
    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "rejects unmanaged pooled streams" do
    client = Tesla.client([ConnectionPool], EmptyAdapter)

    assert {:error, :pooled_streaming_requires_chunks} =
             Tesla.get(client, "http://stream.example/", opts: [adapter: [body_as: :stream]])
  end

  defp worker_for_conn(conn) do
    [worker] =
      Registry.select(Pleroma.Gun.ConnectionPool, [
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
