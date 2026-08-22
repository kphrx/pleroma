# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.HTML
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI.Utils

  import Ecto.Changeset

  @primary_key false
  @derive Jason.Encoder

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        object_fields()
        status_object_fields()
      end
    end

    field(:replies, {:array, ObjectValidators.ObjectID}, default: [])
    field(:source, :map)
  end

  def cast_and_apply(data) do
    data
    |> cast_data()
    |> apply_action(:insert)
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

  defp fix_url(%{"url" => url} = data) when is_bitstring(url), do: data

  defp fix_url(%{"url" => url} = data) when is_map(url) do
    if is_binary(url["href"]) do
      Map.put(data, "url", url["href"])
    else
      Map.delete(data, "url")
    end
  end

  defp fix_url(%{"url" => url} = data) when is_list(url) do
    first_element = Enum.at(url, 0)

    url_string =
      cond do
        is_bitstring(first_element) -> first_element
        is_map(first_element) -> first_element["href"]
        true -> nil
      end

    if is_binary(url_string) do
      Map.put(data, "url", url_string)
    else
      Map.delete(data, "url")
    end
  end

  defp fix_url(data), do: data

  defp fix_tag(%{"tag" => tag} = data) when is_list(tag) do
    Map.put(data, "tag", Enum.filter(tag, &is_map/1))
  end

  defp fix_tag(%{"tag" => tag} = data) when is_map(tag), do: Map.put(data, "tag", [tag])
  defp fix_tag(data), do: Map.drop(data, ["tag"])

  # legacy internal *oma format
  defp fix_replies(%{"replies" => replies} = data) when is_list(replies), do: data

  defp fix_replies(%{"replies" => %{"first" => %{"items" => replies}}} = data)
       when is_list(replies),
       do: Map.put(data, "replies", replies)

  defp fix_replies(%{"replies" => %{"first" => %{"orderedItems" => replies}}} = data)
       when is_list(replies),
       do: Map.put(data, "replies", replies)

  defp fix_replies(%{"replies" => %{"items" => replies}} = data) when is_list(replies),
    do: Map.put(data, "replies", replies)

  defp fix_replies(%{"replies" => %{"orderedItems" => replies}} = data) when is_list(replies),
    do: Map.put(data, "replies", replies)

  defp fix_replies(data), do: Map.delete(data, "replies")

  def fix_attachments(data), do: Transmogrifier.fix_attachments(data)

  defp remote_mention_resolver(
         %{"id" => ap_id, "tag" => tags},
         "@" <> nickname = mention,
         buffer,
         opts,
         acc
       )
       when is_binary(ap_id) and is_list(tags) do
    initial_host =
      ap_id
      |> URI.parse()
      |> Map.get(:host)

    with mention_tag when not is_nil(mention_tag) <-
           Enum.find(tags, &mention_tag?(&1, mention, initial_host)),
         href when is_binary(href) <- mention_tag["href"],
         %User{} = user <- User.get_cached_by_ap_id(href) do
      link = Pleroma.Formatter.mention_from_user(user, opts)
      {link, %{acc | mentions: MapSet.put(acc.mentions, {"@" <> nickname, user})}}
    else
      _ -> {buffer, acc}
    end
  end

  defp remote_mention_resolver(_object, _mention, buffer, _opts, acc), do: {buffer, acc}

  defp mention_tag?(%{"type" => "Mention", "name" => name}, mention, initial_host)
       when is_binary(name) do
    name == mention || mention == "#{name}@#{initial_host}"
  end

  defp mention_tag?(_tag, _mention, _initial_host), do: false

  defp scrub_content(%{"content" => content} = object) when is_binary(content) do
    Map.put(object, "content", HTML.filter_tags(content))
  end

  defp scrub_content(object), do: object

  defp mfm_parse_limit do
    min(Pleroma.Config.get([:instance, :limit]), Pleroma.Config.get([:instance, :remote_limit]))
  end

  defp normalize_source(%{"source" => source} = object) when is_binary(source) do
    object
    |> Map.put("source", %{"content" => source})
    |> normalize_source()
  end

  defp normalize_source(%{"source" => source} = object) when is_map(source) do
    source =
      case source["content"] do
        content when is_binary(content) ->
          if String.length(content) <= mfm_parse_limit() do
            source
          else
            Map.delete(source, "content")
          end

        nil ->
          source

        _ ->
          Map.delete(source, "content")
      end

    Map.put(object, "source", source)
  end

  defp normalize_source(object), do: object

  defp fix_misskey_content(%{"htmlMfm" => true, "content" => content} = object)
       when is_binary(content) do
    Map.put(object, "content", HTML.filter_tags(content))
  end

  defp fix_misskey_content(%{"htmlMfm" => true} = object), do: object

  defp fix_misskey_content(
         %{"source" => %{"mediaType" => "text/x.misskeymarkdown", "content" => content}} = object
       )
       when is_binary(content) do
    mention_handler = fn nick, buffer, opts, acc ->
      remote_mention_resolver(object, nick, buffer, opts, acc)
    end

    {linked, _mentions, _tags} =
      Utils.format_input(content, "text/x.misskeymarkdown", mention_handler: mention_handler)

    Map.put(object, "content", linked)
  end

  defp fix_misskey_content(%{"source" => %{"mediaType" => "text/x.misskeymarkdown"}} = object),
    do: scrub_content(object)

  defp fix_misskey_content(%{"_misskey_content" => content} = object) when is_binary(content) do
    object
    |> Map.put("source", %{
      "content" => content,
      "mediaType" => "text/x.misskeymarkdown"
    })
    |> Map.delete("_misskey_content")
    |> fix_misskey_content()
  end

  defp fix_misskey_content(object), do: object

  defp fix(data) do
    data
    |> CommonFixes.fix_actor()
    |> CommonFixes.fix_object_defaults()
    |> fix_url()
    |> fix_tag()
    |> fix_replies()
    |> fix_attachments()
    |> normalize_source()
    |> fix_misskey_content()
    |> CommonFixes.fix_quote_url()
    |> CommonFixes.fix_likes()
    |> Transmogrifier.fix_emoji()
    |> Transmogrifier.fix_content_map()
    |> CommonFixes.maybe_add_language()
    |> CommonFixes.maybe_add_content_map()
  end

  def changeset(struct, data) do
    data = fix(data)

    struct
    |> cast(data, __schema__(:fields) -- [:attachment, :tag])
    |> cast_embed(:attachment)
    |> cast_embed(:tag)
  end

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["Article", "Note", "Page"])
    |> validate_required([:id, :actor, :attributedTo, :type, :context])
    |> CommonValidations.validate_any_presence([:cc, :to])
    |> CommonValidations.validate_fields_match([:actor, :attributedTo])
    |> CommonValidations.validate_actor_presence()
    |> CommonValidations.validate_host_match()
  end
end
