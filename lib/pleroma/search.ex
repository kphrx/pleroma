defmodule Pleroma.Search do
  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Workers.SearchIndexingWorker

  @spec add_to_index(Activity.t()) :: {:ok, Oban.Job.t() | :noop} | {:error, Oban.Job.changeset()}
  def add_to_index(%Activity{id: activity_id, object: %Object{} = object} = activity) do
    with {_, true} <- {:indexable, indexable?(activity)},
         {_, "public"} <- {:visibility, Visibility.get_visibility(object)} do
      SearchIndexingWorker.new(%{"op" => "add_to_index", "activity" => activity_id})
      |> Oban.insert()
    else
      _ -> {:ok, :noop}
    end
  end

  def add_to_index(%Activity{id: activity_id}) do
    case Activity.get_by_id_with_object(activity_id) do
      %Activity{} = preloaded -> add_to_index(preloaded)
      _ -> :ok
    end
  end

  @spec remove_from_index(Object.t()) :: {:ok, Oban.Job.t()} | {:error, Oban.Job.changeset()}
  def remove_from_index(%Pleroma.Object{id: object_id}) do
    SearchIndexingWorker.new(%{"op" => "remove_from_index", "object" => object_id})
    |> Oban.insert()
  end

  def search(query, options) do
    search_module = Pleroma.Config.get([Pleroma.Search, :module])
    search_module.search(options[:for_user], query, options)
  end

  def healthcheck_endpoints do
    search_module = Pleroma.Config.get([Pleroma.Search, :module])
    search_module.healthcheck_endpoints()
  end

  defp indexable?(%Activity{data: %{"type" => "Create"}}), do: true
  defp indexable?(_), do: false
end
