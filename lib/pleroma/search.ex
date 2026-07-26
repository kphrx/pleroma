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
      _ -> {:ok, :noop}
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

  def object_to_search_data(%Object{} = object) do
    data = object.data

    content_str =
      case data["content"] do
        [nil | rest] -> to_string(rest)
        str -> str
      end

    content =
      with {:ok, scrubbed} <-
             FastSanitize.Sanitizer.scrub(content_str, Pleroma.HTML.Scrubber.SearchIndexing),
           trimmed <- String.trim(scrubbed) do
        trimmed
      end

    # Make sure we have a non-empty string
    if content != "" do
      {:ok, published, _} = DateTime.from_iso8601(data["published"])

      %{
        id: object.id,
        content: content,
        ap: data["id"],
        published: published |> DateTime.to_unix()
      }
    end
  end

  defp indexable?(%Activity{
         data: %{"type" => "Create"},
         object: %Object{
           data: %{"content" => content, "published" => published, "type" => "Note"}
         }
       })
       when not is_nil(content) and content not in ["", "."] and not is_nil(published),
       do: true

  defp indexable?(_), do: false
end
