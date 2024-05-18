# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.QdrantSearchTest do
  use Pleroma.DataCase, async: true
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory
  import Mox

  alias Pleroma.Web.CommonAPI
  alias Pleroma.UnstubbedConfigMock, as: Config
  alias Pleroma.Search.QdrantSearch
  alias Pleroma.Workers.SearchIndexingWorker

  describe "Qdrant search" do
    test "indexes a public post on creation" do
      user = insert(:user)

      Tesla.Mock.mock(fn
        %{method: :post, url: "https://ollama.url/api/embeddings"} ->
          send(self(), "posted_to_ollama")
          Tesla.Mock.json(%{embedding: [1, 2, 3]})

        %{method: :put, url: "https://qdrant.url/collections/posts/points", body: body} ->
          send(self(), "posted_to_qdrant")

          assert match?(%{"points" => [%{"vector" => [1, 2, 3]}]}, Jason.decode!(body))

          Tesla.Mock.json("ok")
      end)

      Config
      |> expect(:get, 4, fn
        [Pleroma.Search, :module], nil ->
          QdrantSearch

        [Pleroma.Search.QdrantSearch, key], nil ->
          %{
            ollama_model: "a_model",
            ollama_url: "https://ollama.url",
            qdrant_url: "https://qdrant.url"
          }[key]
      end)

      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "guys i just don't wanna leave the swamp",
          visibility: "public"
        })

      args = %{"op" => "add_to_index", "activity" => activity.id}

      assert_enqueued(
        worker: SearchIndexingWorker,
        args: args
      )

      assert :ok = perform_job(SearchIndexingWorker, args)
      assert_received("posted_to_ollama")
      assert_received("posted_to_qdrant")
    end
  end
end
