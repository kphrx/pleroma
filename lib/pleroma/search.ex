defmodule Pleroma.Search do
  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Workers.SearchIndexingWorker

  @spec add_to_index(Activity.t()) :: {:ok, Oban.Job.t() | :noop} | {:error, Oban.Job.changeset()}
  def add_to_index(%Activity{id: activity_id, object: %Object{}} = activity) do
    if indexable?(activity) do
      SearchIndexingWorker.new(%{"op" => "add_to_index", "activity" => activity_id})
      |> Oban.insert()
    else
      {:ok, :noop}
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

    content =
      data
      |> search_texts()
      |> Enum.map(&sanitize_search_text/1)
      |> Enum.reject(&(&1 in ["", "."]))
      |> Enum.join(" ")

    with true <- content != "",
         published when is_binary(published) <- data["published"],
         {:ok, published, _} <- DateTime.from_iso8601(published) do
      %{
        id: object.id,
        content: content,
        ap: data["id"],
        published: published |> DateTime.to_unix()
      }
    else
      _ -> nil
    end
  end

  def indexable?(%Activity{
        data: %{"type" => "Create"},
        object: %Object{data: %{"published" => published, "type" => "Note"}} = object
      })
      when not is_nil(published) do
    Visibility.get_visibility(object) in ["public", "unlisted"] and
      not is_nil(object_to_search_data(object))
  end

  def indexable?(_), do: false

  defp search_texts(data) do
    [data["content"], data["summary"] | attachment_names(data["attachment"])]
  end

  defp attachment_names(attachments) when is_list(attachments) do
    Enum.map(attachments, fn
      %{"summary" => summary} when is_binary(summary) -> summary
      %{"name" => name} -> name
      _ -> nil
    end)
  end

  defp attachment_names(_), do: []

  defp sanitize_search_text([nil | rest]), do: sanitize_search_text(to_string(rest))

  defp sanitize_search_text(text) when is_binary(text) do
    case FastSanitize.Sanitizer.scrub(text, Pleroma.HTML.Scrubber.SearchIndexing) do
      {:ok, scrubbed} -> String.trim(scrubbed)
      _ -> ""
    end
  end

  defp sanitize_search_text(_), do: ""
end
