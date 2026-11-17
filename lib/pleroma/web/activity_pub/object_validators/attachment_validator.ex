# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AttachmentValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:id, :string)
    field(:type, :string, default: "Link")
    field(:mediaType, ObjectValidators.MIME, default: "application/octet-stream")
    field(:name, :string)
    field(:summary, :string)
    field(:blurhash, :string)

    embeds_many :url, UrlObjectValidator, primary_key: false do
      field(:type, :string, default: "Link")
      field(:href, ObjectValidators.Uri)
      field(:mediaType, ObjectValidators.MIME, default: "application/octet-stream")
      field(:width, :integer)
      field(:height, :integer)
    end
  end

  def cast_and_validate(data) do
    data
    |> cast_data()
    |> validate_data()
  end

  def cast_data(data) do
    %__MODULE__{}
    |> changeset(data)
  end

  def changeset(struct, data) do
    data =
      data
      |> fix_media_type()
      |> fix_url()
      |> fix_url_media_types()

    struct
    |> cast(data, [:id, :type, :mediaType, :name, :summary, :blurhash])
    |> cast_embed(:url, with: &url_changeset/2, required: true)
    |> validate_inclusion(:type, ~w[Link Document Audio Image Video])
    |> validate_required([:type, :mediaType])
  end

  def url_changeset(struct, data) do
    data = fix_media_type(data)

    struct
    |> cast(data, [:type, :href, :mediaType, :width, :height])
    |> validate_inclusion(:type, ["Link"])
    |> validate_required([:type, :href, :mediaType])
  end

  @unknown_media_types [nil, "", "application/octet-stream"]
  @guessable_media_types ~w[image video audio]

  def fix_media_type(data) do
    media_type =
      Enum.find([data["mediaType"], data["mimeType"]], &(&1 not in @unknown_media_types)) ||
        guess_media_type(data) || "application/octet-stream"

    Map.put(data, "mediaType", media_type)
  end

  # Some servers (e.g. Threads) send no media type. Guess one from the
  # URL extension or the object type, but only image, video or audio:
  # the media type only decides how clients display the attachment.
  defp guess_media_type(data) do
    media_type_from_extension(media_href(data)) || media_type_from_object_type(data["type"])
  end

  defp media_href(%{"url" => url}) when is_binary(url), do: url
  defp media_href(%{"url" => [%{"href" => href} | _]}) when is_binary(href), do: href
  defp media_href(%{"href" => href}) when is_binary(href), do: href
  defp media_href(_), do: nil

  defp media_type_from_extension(href) when is_binary(href) do
    with %URI{path: path} when is_binary(path) <- URI.parse(href),
         "." <> extension <- Path.extname(path),
         media_type <- MIME.type(String.downcase(extension)),
         [kind, _] when kind in @guessable_media_types <- String.split(media_type, "/", parts: 2) do
      media_type
    else
      _ -> nil
    end
  end

  defp media_type_from_extension(_), do: nil

  defp media_type_from_object_type("Image"), do: "image/*"
  defp media_type_from_object_type("Video"), do: "video/*"
  defp media_type_from_object_type("Audio"), do: "audio/*"
  defp media_type_from_object_type(_), do: nil

  # Url links without a known media type of their own take the attachment's.
  defp fix_url_media_types(%{"url" => urls, "mediaType" => media_type} = data)
       when is_list(urls) do
    Map.put(data, "url", Enum.map(urls, &fix_url_media_type(&1, media_type)))
  end

  defp fix_url_media_types(data), do: data

  defp fix_url_media_type(%{} = url, media_type) do
    case fix_media_type(url) do
      %{"mediaType" => "application/octet-stream"} = url -> Map.put(url, "mediaType", media_type)
      url -> url
    end
  end

  defp fix_url_media_type(url, _media_type), do: url

  defp handle_href(href, mediaType, data) do
    [
      %{
        "href" => href,
        "type" => "Link",
        "mediaType" => mediaType,
        "width" => data["width"],
        "height" => data["height"]
      }
    ]
  end

  defp fix_url(data) do
    cond do
      is_binary(data["url"]) ->
        Map.put(data, "url", handle_href(data["url"], data["mediaType"], data))

      is_binary(data["href"]) and data["url"] == nil ->
        Map.put(data, "url", handle_href(data["href"], data["mediaType"], data))

      true ->
        data
    end
  end

  defp validate_data(cng) do
    cng
    |> validate_inclusion(:type, ~w[Document Audio Image Video])
    |> validate_required([:mediaType, :type])
  end
end
