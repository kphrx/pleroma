# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes do
  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Language.LanguageDetector
  alias Pleroma.Maps
  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils

  import Pleroma.EctoType.ActivityPub.ObjectValidators.LanguageCode,
    only: [good_locale_code?: 1]

  import Pleroma.Web.Utils.Guards, only: [not_empty_string: 1]

  require Pleroma.Constants

  def cast_and_filter_recipients(message, field, follower_collection, field_fallback \\ []) do
    # Fix as:Public/Public before ObjectID casting drops it, but keep `field_fallback`
    # semantics (only used when the field is missing).
    recipients =
      %{field => message[field] || field_fallback}
      |> Transmogrifier.fix_addressing_list(field)
      |> Transmogrifier.fix_addressing_public(field)
      |> Map.fetch!(field)

    {:ok, data} = ObjectValidators.Recipients.cast(recipients)

    data =
      Enum.reject(data, fn x ->
        String.ends_with?(x, "/followers") and x != follower_collection
      end)

    Map.put(message, field, data)
  end

  def fix_object_defaults(data) do
    data = Maps.filter_empty_values(data)

    in_reply_to_id = in_reply_to_id(data["inReplyTo"])

    context =
      Utils.maybe_create_context(
        data["context"] || data["conversation"] || in_reply_to_id || data["id"]
      )

    data = Map.put(data, "context", context)

    with attributed_to when is_binary(attributed_to) <- data["attributedTo"],
         %User{follower_address: follower_collection} <- User.get_cached_by_ap_id(attributed_to) do
      data
      |> cast_and_filter_recipients("to", follower_collection)
      |> cast_and_filter_recipients("cc", follower_collection)
      |> cast_and_filter_recipients("bto", follower_collection)
      |> cast_and_filter_recipients("bcc", follower_collection)
      |> Transmogrifier.fix_implicit_addressing(follower_collection)
    else
      _ -> data
    end
  end

  defp in_reply_to_id(in_reply_to) when is_binary(in_reply_to), do: in_reply_to
  defp in_reply_to_id(%{"id" => in_reply_to}) when is_binary(in_reply_to), do: in_reply_to
  defp in_reply_to_id(%{"href" => in_reply_to}) when is_binary(in_reply_to), do: in_reply_to
  defp in_reply_to_id([in_reply_to | _]), do: in_reply_to_id(in_reply_to)
  defp in_reply_to_id(_), do: nil

  def fix_activity_addressing(activity) do
    %User{follower_address: follower_collection} = User.get_cached_by_ap_id(activity["actor"])

    activity
    |> cast_and_filter_recipients("to", follower_collection)
    |> cast_and_filter_recipients("cc", follower_collection)
    |> cast_and_filter_recipients("bto", follower_collection)
    |> cast_and_filter_recipients("bcc", follower_collection)
    |> Transmogrifier.fix_implicit_addressing(follower_collection)
  end

  def fix_actor(data) do
    actor =
      data
      |> Map.put_new("actor", data["attributedTo"])
      |> Containment.get_actor()

    data
    |> Map.put("actor", actor)
    |> Map.put("attributedTo", actor)
  end

  def maybe_set_attributed_to_from_activity(object, activity) when is_map(object) do
    if is_nil(object["attributedTo"]) and is_nil(object["actor"]) do
      case Containment.get_actor(activity) do
        actor when is_binary(actor) -> Map.put(object, "attributedTo", actor)
        _ -> object
      end
    else
      object
    end
  end

  def fix_activity_context(data, %Object{data: %{"context" => object_context}}) do
    data
    |> Map.put("context", object_context)
  end

  def fix_object_action_recipients(%{"actor" => actor} = data, %Object{data: %{"actor" => actor}}) do
    to = ((data["to"] || []) -- [actor]) |> Enum.uniq()

    Map.put(data, "to", to)
  end

  def fix_object_action_recipients(data, %Object{data: %{"actor" => actor}}) do
    to = ((data["to"] || []) ++ [actor]) |> Enum.uniq()

    Map.put(data, "to", to)
  end

  def fix_quote_url(%{"quoteUrl" => quote_url} = data) do
    case normalize_object_id(quote_url) do
      quote_url when is_binary(quote_url) -> Map.put(data, "quoteUrl", quote_url)
      _ -> Map.delete(data, "quoteUrl")
    end
  end

  # Fedibird
  # https://github.com/fedibird/mastodon/commit/dbd7ae6cf58a92ec67c512296b4daaea0d01e6ac
  def fix_quote_url(%{"quoteUri" => quote_url} = data) do
    case normalize_object_id(quote_url) do
      quote_url when is_binary(quote_url) -> Map.put(data, "quoteUrl", quote_url)
      _ -> data
    end
  end

  # Old Fedibird (bug)
  # https://github.com/fedibird/mastodon/issues/9
  def fix_quote_url(%{"quoteURL" => quote_url} = data) do
    case normalize_object_id(quote_url) do
      quote_url when is_binary(quote_url) -> Map.put(data, "quoteUrl", quote_url)
      _ -> data
    end
  end

  # Misskey fallback
  def fix_quote_url(%{"_misskey_quote" => quote_url} = data) do
    case normalize_object_id(quote_url) do
      quote_url when is_binary(quote_url) -> Map.put(data, "quoteUrl", quote_url)
      _ -> data
    end
  end

  def fix_quote_url(%{"tag" => [_ | _] = tags} = data) do
    tag = Enum.find(tags, &object_link_tag?/1)

    if not is_nil(tag) do
      data
      |> Map.put("quoteUrl", tag["href"])
    else
      data
    end
  end

  def fix_quote_url(data), do: data

  defp normalize_object_id(object_id) when is_binary(object_id), do: object_id
  defp normalize_object_id(%{"id" => object_id}) when is_binary(object_id), do: object_id
  defp normalize_object_id([object_id | _]) when is_binary(object_id), do: object_id
  defp normalize_object_id(_), do: nil

  # On Mastodon, `"likes"` attribute includes an inlined `Collection` with `totalItems`,
  # not a list of users.
  # https://github.com/mastodon/mastodon/pull/32007
  def fix_likes(%{"likes" => %{}} = data), do: Map.drop(data, ["likes"])

  def fix_likes(data), do: data

  # https://codeberg.org/fediverse/fep/src/branch/main/fep/e232/fep-e232.md
  def object_link_tag?(%{
        "type" => "Link",
        "mediaType" => media_type,
        "href" => href
      })
      when media_type in Pleroma.Constants.activity_json_mime_types() and is_binary(href) do
    true
  end

  def object_link_tag?(_), do: false

  def maybe_add_language_from_activity(object, activity) do
    language = get_language_from_context(activity)

    if language do
      Map.put(object, "language", language)
    else
      object
    end
  end

  def maybe_add_language(object) do
    language =
      [
        &get_language_from_context/1,
        &get_language_from_content_map/1,
        &get_language_from_content/1
      ]
      |> Enum.find_value(fn get_language ->
        language = get_language.(object)

        if good_locale_code?(language) do
          language
        else
          nil
        end
      end)

    if language do
      Map.put(object, "language", language)
    else
      object
    end
  end

  defp get_language_from_context(%{"@context" => context}) when is_list(context) do
    case context
         |> Enum.find(fn
           %{"@language" => language} -> language != "und"
           _ -> nil
         end) do
      %{"@language" => language} -> language
      _ -> nil
    end
  end

  defp get_language_from_context(_), do: nil

  defp get_language_from_content_map(%{"contentMap" => content_map, "content" => source_content}) do
    content_groups = Map.to_list(content_map)

    case Enum.find(content_groups, fn {_, content} -> content == source_content end) do
      {language, _} -> language
      _ -> nil
    end
  end

  defp get_language_from_content_map(_), do: nil

  defp get_language_from_content(%{"content" => content} = object) do
    LanguageDetector.detect("#{object["summary"] || ""} #{content}")
  end

  defp get_language_from_content(_), do: nil

  def maybe_add_content_map(%{"language" => language, "content" => content} = object)
      when not_empty_string(language) do
    Map.put(object, "contentMap", Map.put(%{}, language, content))
  end

  def maybe_add_content_map(object), do: object
end
