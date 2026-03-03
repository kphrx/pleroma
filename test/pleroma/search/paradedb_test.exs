# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.ParadeDBTest do
  use Pleroma.DataCase, async: true
  use Oban.Testing, repo: Pleroma.Repo

  import Mox
  import Pleroma.Factory

  alias Pleroma.Search.ParadeDB
  alias Pleroma.Search.ParadeDB.ClientMock
  alias Pleroma.UnstubbedConfigMock, as: Config
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.SearchIndexingWorker

  describe "ParadeDB" do
    test "indexes a public post on creation" do
      user = insert(:user)

      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "guys i just don't wanna leave the swamp",
          visibility: "public"
        })

      args = %{"op" => "add_to_index", "activity" => activity.id}

      assert_enqueued(worker: SearchIndexingWorker, args: args)

      ClientMock
      |> expect(:query, fn sql, params ->
        assert sql =~ "INSERT INTO pleroma_search_documents"

        [activity_id, object_id, object_ap_id, actor_ap_id, content, published_at] = params

        assert activity_id == activity.id
        assert is_integer(object_id)
        assert is_binary(object_ap_id)
        assert actor_ap_id == activity.data["actor"]
        assert content == "guys i just don&#39;t wanna leave the swamp"
        assert %DateTime{} = published_at

        send(self(), :inserted)
        {:ok, %{}}
      end)

      Config
      |> expect(:get, 3, fn
        [Pleroma.Search, :module], nil ->
          ParadeDB

        [Pleroma.Search.ParadeDB, :client_impl], nil ->
          ClientMock

        [Pleroma.Search.ParadeDB, :table], "pleroma_search_documents" ->
          "pleroma_search_documents"
      end)

      assert :ok = perform_job(SearchIndexingWorker, args)
      assert_received(:inserted)
    end

    test "doesn't index posts that are not public" do
      user = insert(:user)

      Enum.each(["private", "direct"], fn visibility ->
        {:ok, activity} =
          CommonAPI.post(user, %{
            status: "guys i just don't wanna leave the swamp",
            visibility: visibility
          })

        args = %{"op" => "add_to_index", "activity" => activity.id}
        assert_enqueued(worker: SearchIndexingWorker, args: args)

        Config
        |> expect(:get, fn
          [Pleroma.Search, :module], nil ->
            ParadeDB
        end)

        assert :ok = perform_job(SearchIndexingWorker, args)
      end)
    end

    test "deletes posts from index when deleted locally" do
      user = insert(:user)

      ClientMock
      |> expect(:query, 2, fn sql, params ->
        cond do
          String.contains?(sql, "INSERT INTO pleroma_search_documents") ->
            send(self(), :inserted)
            {:ok, %{}}

          String.contains?(sql, "DELETE FROM pleroma_search_documents") ->
            assert [object_id] = params
            assert is_integer(object_id)

            send(self(), :deleted)
            {:ok, %{}}

          true ->
            flunk("Unexpected ParadeDB SQL: #{inspect(sql)}")
        end
      end)

      Config
      |> expect(:get, 6, fn
        [Pleroma.Search, :module], nil ->
          ParadeDB

        [Pleroma.Search.ParadeDB, :client_impl], nil ->
          ClientMock

        [Pleroma.Search.ParadeDB, :table], "pleroma_search_documents" ->
          "pleroma_search_documents"
      end)

      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "guys i just don't wanna leave the swamp",
          visibility: "public"
        })

      args = %{"op" => "add_to_index", "activity" => activity.id}
      assert_enqueued(worker: SearchIndexingWorker, args: args)
      assert :ok = perform_job(SearchIndexingWorker, args)
      assert_received(:inserted)

      {:ok, _} = CommonAPI.delete(activity.id, user)

      delete_args = %{"op" => "remove_from_index", "object" => activity.object.id}
      assert_enqueued(worker: SearchIndexingWorker, args: delete_args)
      assert :ok = perform_job(SearchIndexingWorker, delete_args)
      assert_received(:deleted)
    end

    test "search returns activities in backend order" do
      user = insert(:user)

      {:ok, activity1} = CommonAPI.post(user, %{status: "first swamp", visibility: "public"})
      {:ok, activity2} = CommonAPI.post(user, %{status: "second swamp", visibility: "public"})

      ClientMock
      |> expect(:query, fn sql, params ->
        assert sql =~ "SELECT id FROM pleroma_search_documents"
        assert ["swamp", _limit, _offset] = params

        {:ok, %{rows: [[activity2.id], [activity1.id]]}}
      end)

      Config
      |> expect(:get, 2, fn
        [Pleroma.Search.ParadeDB, :client_impl], nil ->
          ClientMock

        [Pleroma.Search.ParadeDB, :table], "pleroma_search_documents" ->
          "pleroma_search_documents"
      end)

      assert [%{id: ^activity2.id}, %{id: ^activity1.id}] =
               ParadeDB.search(nil, "swamp", limit: 40, offset: 0)
    end
  end
end
