defmodule Pleroma.Search do
  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Workers.SearchIndexingWorker

  @spec add_to_index(Activity.t()) :: :ok | :error
  def add_to_index(%Pleroma.Activity{id: activity_id} = activity) do
    with true <- indexable?(activity),
         {:ok, %Oban.Job{}} <-
           SearchIndexingWorker.enqueue("add_to_index", %{"activity" => activity_id}) do
      :ok
    else
      false -> :ok
      _ -> :error
    end
  end

  @spec remove_from_index(Object.t()) :: :ok | :error
  def remove_from_index(%Pleroma.Object{id: object_id}) do
    case SearchIndexingWorker.enqueue("remove_from_index", %{"object" => object_id}) do
      {:ok, %Oban.Job{}} -> :ok
      _ -> :error
    end
  end

  def search(query, options) do
    search_module = Pleroma.Config.get([Pleroma.Search, :module])
    search_module.search(options[:for_user], query, options)
  end

  def healthcheck_endpoints do
    search_module = Pleroma.Config.get([Pleroma.Search, :module])
    search_module.healthcheck_endpoints
  end

  defp indexable?(%Activity{object: %Object{}, data: %{"type" => "Create"}}), do: true
  defp indexable?(_), do: false
end
