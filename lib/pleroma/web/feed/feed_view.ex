# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Feed.FeedView do
  use Phoenix.HTML
  use Pleroma.Web, :view

  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.Gettext
  alias Pleroma.Web.MediaProxy

  require Pleroma.Constants

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def prepare_activity(activity, opts \\ []) do
    object = Object.normalize(activity, fetch: false)

    actor =
      if opts[:actor] do
        Pleroma.User.get_cached_by_ap_id(activity.actor)
      end

    %{
      activity: activity,
      object: object,
      data: Map.get(object, :data),
      actor: actor
    }
  end

  def most_recent_update(activities) do
    with %{updated_at: updated_at} <- List.first(activities) do
      to_rfc3339(updated_at)
    end
  end

  def most_recent_update(activities, user, :atom) do
    (List.first(activities) || user).updated_at
    |> to_rfc3339()
  end

  def most_recent_update(activities, user, :rss) do
    (List.first(activities) || user).updated_at
    |> to_rfc2822()
  end

  def feed_logo do
    case Pleroma.Config.get([:feed, :logo]) do
      nil ->
        "#{Pleroma.Web.Endpoint.url()}/static/logo.svg"

      logo ->
        "#{Pleroma.Web.Endpoint.url()}#{logo}"
    end
    |> MediaProxy.url()
  end

  def email(user) do
    user.nickname <> "@" <> Pleroma.Web.Endpoint.host()
  end

  def logo(user) do
    user
    |> User.avatar_url()
    |> MediaProxy.url()
  end

  def last_activity(activities), do: List.last(activities)

  def activity_title(%{"content" => content} = data, opts \\ %{}) do
    summary = Map.get(data, "summary", "")

    title =
      cond do
        summary != "" -> summary
        content != "" -> activity_content(data)
        true -> "a post"
      end

    title
    |> Pleroma.Web.Metadata.Utils.scrub_html_and_truncate(opts[:max_length], opts[:omission])
    |> HtmlEntities.encode()
  end

  def activity_description(data) do
    content = activity_content(data)
    summary = data["summary"]

    cond do
      content != "" -> escape(content)
      summary != "" -> escape(summary)
      true -> escape(data["type"])
    end
  end

  def rss_content_encoded(data) do
    data
    |> feed_content_encoded()
    |> String.replace("]]>", "]]&gt;")
  end

  def atom_content_encoded(data), do: feed_content_encoded(data)

  defp feed_content_encoded(data) do
    base_content =
      case activity_content(data) do
        "" ->
          (data["summary"] || data["type"] || "")
          |> escape()

        content ->
          content
      end

    attachments_html =
      if data["sensitive"] do
        ""
      else
        (data["attachment"] || [])
        |> Enum.map(&rss_attachment_preview/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("<br/><br/>")
      end

    [base_content, attachments_html]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("<br/><br/>")
  end

  defp rss_attachment_preview(attachment) do
    href = attachment_href(attachment)

    if is_binary(href) and href != "" do
      media_type = attachment_type(attachment) || "application/octet-stream"
      escaped_href = escape(href)
      name = attachment["name"] || "Attachment"
      escaped_name = escape(name)

      cond do
        String.starts_with?(media_type, "image/") ->
          ~s(<p><img src="#{escaped_href}" alt="#{escaped_name}" loading="lazy"/></p>)

        String.starts_with?(media_type, "video/") ->
          ~s(<p><video controls preload="metadata" src="#{escaped_href}"></video></p><p><a href="#{escaped_href}">#{escaped_name}</a></p>)

        String.starts_with?(media_type, "audio/") ->
          ~s(<p><audio controls preload="metadata" src="#{escaped_href}"></audio></p><p><a href="#{escaped_href}">#{escaped_name}</a></p>)

        true ->
          ~s(<p><a href="#{escaped_href}">#{escaped_name}</a></p>)
      end
    else
      ""
    end
  end

  def activity_content(%{"content" => content}) do
    content
    |> String.replace(~r/[\n\r]/, "")
  end

  def activity_content(_), do: ""

  def activity_context(activity), do: escape(activity.data["context"])

  def feed_self_url(conn), do: Phoenix.Controller.current_url(conn)

  def activity_link(activity, data) do
    cond do
      activity.local -> data["id"] || data["url"]
      true -> data["external_url"] || data["id"] || data["url"]
    end
  end

  def attachment_href(attachment) do
    attachment
    |> attachment_url_data()
    |> Map.get("href")
  end

  def attachment_type(attachment) do
    attachment
    |> attachment_url_data()
    |> Map.get("mediaType") || attachment["mediaType"]
  end

  def attachment_size(attachment) do
    attachment
    |> attachment_url_data()
    |> Map.get("size", 0)
  end

  def attachment_size_positive(attachment) do
    case attachment_size(attachment) do
      size when is_integer(size) and size > 0 ->
        size

      size when is_binary(size) ->
        case Integer.parse(size) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def attachment_medium(attachment) do
    case attachment_type(attachment) do
      "image/" <> _rest -> "image"
      "video/" <> _rest -> "video"
      "audio/" <> _rest -> "audio"
      _ -> "document"
    end
  end

  def attachment_previewable?(attachment) do
    attachment_medium(attachment) in ["image", "video", "audio"]
  end

  def attachment_description(attachment) do
    attachment["name"] || ""
  end

  def media_content_xml(_attachment, true), do: ""

  def media_content_xml(attachment, _sensitive) do
    href = escape(attachment_href(attachment) || "")
    type = escape(attachment_type(attachment) || "application/octet-stream")
    medium = escape(attachment_medium(attachment))

    file_size_attr =
      case attachment_size_positive(attachment) do
        size when is_integer(size) -> ~s( fileSize="#{size}")
        _ -> ""
      end

    case attachment_description(attachment) do
      "" ->
        ~s(<media:content url="#{href}" type="#{type}"#{file_size_attr} medium="#{medium}"/>\n)

      description ->
        """
        <media:content url="#{href}" type="#{type}"#{file_size_attr} medium="#{medium}">
          <media:description type="plain">#{escape(description)}</media:description>
        </media:content>
        """
    end
  end

  defp attachment_url_data(attachment) do
    case attachment["url"] do
      [first | _] when is_map(first) -> first
      %{} = map -> map
      _ -> %{}
    end
  end

  def get_href(id) do
    with %Object{data: %{"external_url" => external_url}} <- Object.get_cached_by_ap_id(id) do
      external_url
    else
      _e -> id
    end
  end

  def escape(html) do
    html
    |> html_escape()
    |> safe_to_string()
  end

  @spec to_rfc3339(String.t() | NaiveDateTime.t()) :: String.t()
  def to_rfc3339(date) when is_binary(date) do
    date
    |> Timex.parse!("{ISO:Extended}")
    |> to_rfc3339()
  end

  def to_rfc3339(nd) do
    nd
    |> Timex.to_datetime()
    |> Timex.format!("{RFC3339}")
  end

  @spec to_rfc2822(String.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def to_rfc2822(datestr) when is_binary(datestr) do
    datestr
    |> Timex.parse!("{ISO:Extended}")
    |> to_rfc2822()
  end

  def to_rfc2822(%DateTime{} = date) do
    date
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> rfc2822_from_erl()
  end

  def to_rfc2822(nd) do
    nd
    |> Timex.to_datetime()
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> rfc2822_from_erl()
  end

  @doc """
  Builds a RFC2822 timestamp from an Erlang timestamp
  [RFC2822 3.3 - Date and Time Specification](https://tools.ietf.org/html/rfc2822#section-3.3)
  This function always assumes the Erlang timestamp is in Universal time, not Local time
  """
  def rfc2822_from_erl({{year, month, day} = date, {hour, minute, second}}) do
    day_name = Enum.at(@days, :calendar.day_of_the_week(date) - 1)
    month_name = Enum.at(@months, month - 1)

    date_part = "#{day_name}, #{day} #{month_name} #{year}"
    time_part = "#{pad(hour)}:#{pad(minute)}:#{pad(second)}"

    date_part <> " " <> time_part <> " +0000"
  end

  defp pad(num) do
    num
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end
end
