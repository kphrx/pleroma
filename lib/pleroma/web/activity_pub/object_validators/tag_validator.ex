# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.TagValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators

  import Ecto.Changeset

  require Pleroma.Constants

  @primary_key false
  embedded_schema do
    # Common
    field(:type, :string)
    field(:name, :string)

    # Mention, Hashtag, Link
    field(:href, ObjectValidators.Uri)

    # Link
    field(:mediaType, :string)

    # Emoji
    embeds_one :icon, IconObjectValidator, primary_key: false do
      field(:type, :string)
      field(:url, ObjectValidators.Uri)
    end

    field(:updated, ObjectValidators.DateTime)
    field(:id, ObjectValidators.Uri)
  end

  def cast_and_validate(data) do
    data
    |> cast_data()
  end

  def cast_data(data) do
    %__MODULE__{}
    |> changeset(data)
  end

  def changeset(struct, %{"type" => "Mention"} = data) do
    struct
    |> cast(data, [:type, :name, :href])
    |> validate_required([:type, :href])
  end

  def changeset(struct, %{"type" => "Hashtag", "name" => name} = data) do
    name = String.downcase(name)
    data = Map.put(data, "name", name)

    struct
    |> cast(data, [:type, :name, :href])
    |> validate_required([:type, :name])
  end

  def changeset(struct, %{"type" => "Emoji"} = data) do
    data =
      data
      |> Map.put("name", String.trim(data["name"], ":"))
      |> normalize_emoji_icon()

    case data["icon"] do
      %{"url" => url} when is_binary(url) ->
        if valid_http_url?(url) do
          struct
          |> cast(data, [:type, :name, :updated, :id])
          |> cast_embed(:icon, with: &icon_changeset/2)
          |> validate_required([:type, :name, :icon])
        else
          struct
          |> cast(data, [])
          |> Map.put(:action, :ignore)
        end

      _ ->
        struct
        |> cast(data, [])
        |> Map.put(:action, :ignore)
    end
  end

  def changeset(struct, %{"type" => "Link"} = data) do
    struct
    |> cast(data, [:type, :name, :mediaType, :href])
    |> validate_inclusion(:mediaType, Pleroma.Constants.activity_json_mime_types())
    |> validate_required([:type, :href, :mediaType])
  end

  def changeset(struct, %{"type" => _} = data) do
    struct
    |> cast(data, [])
    |> Map.put(:action, :ignore)
  end

  def changeset(struct, data) when is_map(data) do
    data = infer_type(data)

    if Map.has_key?(data, "type") do
      changeset(struct, data)
    else
      struct
      |> cast(data, [])
      |> Map.put(:action, :ignore)
    end
  end

  defp infer_type(%{"type" => _} = data), do: data
  defp infer_type(%{"name" => "#" <> _} = data), do: Map.put(data, "type", "Hashtag")
  defp infer_type(%{"name" => "@" <> _} = data), do: Map.put(data, "type", "Mention")

  defp infer_type(%{"mediaType" => _media_type, "href" => _href} = data),
    do: Map.put(data, "type", "Link")

  defp infer_type(data), do: data

  defp normalize_emoji_icon(%{"icon" => icon} = data) when is_binary(icon) do
    Map.put(data, "icon", %{"type" => "Image", "url" => icon})
  end

  defp normalize_emoji_icon(%{"icon" => icon} = data) when is_map(icon) do
    case extract_icon_url(icon) do
      url when is_binary(url) -> Map.put(data, "icon", %{"type" => "Image", "url" => url})
      _ -> Map.delete(data, "icon")
    end
  end

  defp normalize_emoji_icon(data), do: data

  defp extract_icon_url(%{"url" => url}) when is_binary(url), do: url

  defp extract_icon_url(%{"url" => %{"href" => href}}) when is_binary(href), do: href

  defp extract_icon_url(%{"url" => [first | _]}) do
    cond do
      is_binary(first) -> first
      is_map(first) -> first["href"]
      true -> nil
    end
  end

  defp extract_icon_url(%{"href" => href}) when is_binary(href), do: href

  defp extract_icon_url(_), do: nil

  defp valid_http_url?(url) when is_binary(url) do
    match?({:ok, _}, ObjectValidators.Uri.cast(url))
  end

  defp valid_http_url?(_), do: false

  def icon_changeset(struct, data) do
    struct
    |> cast(data, [:type, :url])
    |> validate_inclusion(:type, ~w[Image])
    |> validate_required([:type, :url])
  end
end
