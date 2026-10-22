# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Formatter do
  require Logger

  alias Pleroma.HTML
  alias Pleroma.User

  @safe_mention_regex ~r/^(\s*(?<mentions>(@.+?\s+){1,})+)(?<rest>.*)/s
  @link_regex ~r"((?:http(s)?:\/\/)?[\w.-]+(?:\.[\w\.-]+)+[\w\-\._~%:/?#[\]@!\$&'\(\)\*\+,;=.]+)|[0-9a-z+\-\.]+:[0-9a-z$-_.+!*'(),]+"ui
  @markdown_characters_regex ~r/(`|\*|_|{|}|[|]|\(|\)|#|\+|-|\.|!)/
  @markdown_void_elements ~w[area base br col command embed hr img input keygen link meta param source track wbr]

  defp linkify_opts do
    Pleroma.Config.get(Pleroma.Formatter) ++
      [
        hashtag: true,
        hashtag_handler: &Pleroma.Formatter.hashtag_handler/4,
        mention: true,
        mention_handler: &Pleroma.Formatter.mention_handler/4
      ]
  end

  def escape_mention_handler("@" <> nickname = mention, buffer, _, _) do
    case User.get_cached_by_nickname(nickname) do
      %User{} ->
        # escape markdown characters with `\\`
        # (we don't want something like @user__name to be parsed by markdown)
        String.replace(mention, @markdown_characters_regex, "\\\\\\1")

      _ ->
        buffer
    end
  end

  def mention_handler("@" <> nickname, buffer, opts, acc) do
    case User.get_cached_by_nickname(nickname) do
      %User{} = user ->
        {mention_from_user(user, opts),
         %{acc | mentions: MapSet.put(acc.mentions, {"@" <> nickname, user})}}

      _ ->
        {buffer, acc}
    end
  end

  def mention_from_user(%User{id: id} = user, opts \\ %{mentions_format: :full}) do
    user_url = user.uri || user.ap_id
    nickname_text = get_nickname_text(user.nickname, opts)

    Phoenix.HTML.Tag.content_tag(
      :span,
      Phoenix.HTML.Tag.content_tag(
        :a,
        ["@", Phoenix.HTML.Tag.content_tag(:span, nickname_text)],
        "data-user": id,
        class: "u-url mention",
        href: user_url,
        rel: "ugc"
      ),
      class: "h-card"
    )
    |> Phoenix.HTML.safe_to_string()
  end

  def hashtag_handler("#" <> tag = tag_text, _buffer, _opts, acc) do
    tag = String.downcase(tag)
    url = "#{Pleroma.Web.Endpoint.url()}/tag/#{tag}"

    link =
      Phoenix.HTML.Tag.content_tag(:a, tag_text,
        class: "hashtag",
        "data-tag": tag,
        href: url,
        rel: "tag ugc"
      )
      |> Phoenix.HTML.safe_to_string()

    {link, %{acc | tags: MapSet.put(acc.tags, {tag_text, tag})}}
  end

  @doc """
  Parses a text and replace plain text links with HTML. Returns a tuple with a result text, mentions, and hashtags.

  If the 'safe_mention' option is given, only consecutive mentions at the start the post are actually mentioned.
  """
  @spec linkify(String.t(), keyword()) ::
          {String.t(), [{String.t(), User.t()}], [{String.t(), String.t()}]}
  def linkify(text, options \\ []) do
    options = linkify_opts() ++ options

    if options[:safe_mention] && Regex.named_captures(@safe_mention_regex, text) do
      %{"mentions" => mentions, "rest" => rest} = Regex.named_captures(@safe_mention_regex, text)
      acc = %{mentions: MapSet.new(), tags: MapSet.new()}

      {text_mentions, %{mentions: mentions}} = Linkify.link_map(mentions, acc, options)
      {text_rest, %{tags: tags}} = Linkify.link_map(rest, acc, options)

      {text_mentions <> text_rest, MapSet.to_list(mentions), MapSet.to_list(tags)}
    else
      acc = %{mentions: MapSet.new(), tags: MapSet.new()}
      {text, %{mentions: mentions, tags: tags}} = Linkify.link_map(text, acc, options)

      {text, MapSet.to_list(mentions), MapSet.to_list(tags)}
    end
  end

  @doc """
  Escapes a special characters in mention names.
  """
  def mentions_escape(text, options \\ []) do
    options =
      Keyword.merge(options,
        mention: true,
        url: false,
        mention_handler: &Pleroma.Formatter.escape_mention_handler/4
      )

    if options[:safe_mention] && Regex.named_captures(@safe_mention_regex, text) do
      %{"mentions" => mentions, "rest" => rest} = Regex.named_captures(@safe_mention_regex, text)
      Linkify.link(mentions, options) <> Linkify.link(rest, options)
    else
      Linkify.link(text, options)
    end
  end

  def markdown_to_html(text) do
    markdown_to_html(text, %{})
  end

  def markdown_to_html(text, opts) do
    breaks = Map.get(opts, :breaks, false)

    {_status, ast, _messages} = EarmarkParser.as_ast(text, breaks: breaks, gfm: true)

    ast
    |> maybe_strip_email_autolinks(text, Map.get(opts, :strip_email_autolinks, false))
    |> render_markdown_nodes(false)
    |> IO.iodata_to_binary()
  rescue
    exception ->
      Logger.warning("Markdown rendering failed in #{inspect(exception.__struct__)}")
      markdown_fallback(text, Map.get(opts, :breaks, false))
  end

  defp markdown_fallback(text, breaks) do
    text = text |> escape_html() |> IO.iodata_to_binary() |> maybe_render_markdown_breaks(breaks)
    "<p>" <> text <> "</p>"
  end

  defp maybe_render_markdown_breaks(text, true), do: String.replace(text, ~r/\r?\n/, "<br>")
  defp maybe_render_markdown_breaks(text, false), do: text

  defp maybe_strip_email_autolinks(ast, _text, false), do: ast

  defp maybe_strip_email_autolinks(ast, text, true) do
    emails =
      ~r/<([^ >]+@[^ >]+)>/
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [email] -> String.replace_prefix(email, "mailto:", "") end)
      |> MapSet.new()

    strip_email_autolinks(ast, emails)
  end

  defp strip_email_autolinks(nodes, emails) when is_list(nodes) do
    Enum.map(nodes, &strip_email_autolinks(&1, emails))
  end

  defp strip_email_autolinks({"a", attrs, [email], _meta} = node, emails)
       when is_binary(email) do
    if List.keyfind(attrs, "href", 0) == {"href", "mailto:" <> email} and
         MapSet.member?(emails, email) do
      email
    else
      node
    end
  end

  defp strip_email_autolinks({tag, attrs, children, meta}, emails) do
    {tag, attrs, strip_email_autolinks(children, emails), meta}
  end

  defp strip_email_autolinks(text, _emails) when is_binary(text), do: text

  defp render_markdown_nodes(nodes, verbatim) when is_list(nodes) do
    Enum.map(nodes, &render_markdown_node(&1, verbatim))
  end

  defp render_markdown_node(text, true) when is_binary(text),
    do: strip_dangerous_markdown_html(text)

  defp render_markdown_node(text, false) when is_binary(text) do
    text
    |> strip_dangerous_markdown_html()
    |> escape_markdown_html()
  end

  defp render_markdown_node({:comment, _attrs, _children, _meta}, _verbatim), do: []

  defp render_markdown_node({tag, attrs, children, meta}, verbatim) do
    normalized_tag = String.downcase(tag)

    if normalized_tag in ["script", "style"] do
      []
    else
      render_markdown_element(tag, normalized_tag, attrs, children, meta, verbatim)
    end
  end

  defp render_markdown_element("code", _normalized_tag, attrs, children, _meta, _verbatim) do
    ["<code", render_markdown_attrs(attrs), ">", render_markdown_code(children), "</code>"]
  end

  defp render_markdown_element(tag, "hr", attrs, _children, _meta, _verbatim) do
    attrs = Enum.reject(attrs, &match?({"class", class} when class in ~w[thin medium thick], &1))
    ["<", tag, render_markdown_attrs(attrs), "/>"]
  end

  defp render_markdown_element(tag, normalized_tag, attrs, _children, _meta, _verbatim)
       when normalized_tag in @markdown_void_elements do
    ["<", tag, render_markdown_attrs(attrs), ">"]
  end

  defp render_markdown_element(tag, _normalized_tag, attrs, children, meta, verbatim) do
    children_verbatim = verbatim or Map.get(meta, :verbatim, false)

    [
      "<",
      tag,
      render_markdown_attrs(attrs),
      ">",
      render_markdown_nodes(children, children_verbatim),
      "</",
      tag,
      ">"
    ]
  end

  defp render_markdown_attrs(attrs) do
    Enum.map(attrs, fn {name, value} ->
      value = value |> to_string() |> HtmlEntities.decode() |> sanitize_markdown_url(name)
      [" ", to_string(name), "=\"", escape_html(value), "\""]
    end)
  end

  defp render_markdown_code(children) do
    Enum.map(children, &escape_html/1)
  end

  defp sanitize_markdown_url(value, name) do
    if String.downcase(to_string(name)) in ["href", "src"] do
      # Percent-encode instead of cutting, so the URL stays complete but can
      # never close the attribute or open a tag.
      String.replace(value, ~r/["<>]/, fn
        "\"" -> "%22"
        "<" -> "%3C"
        ">" -> "%3E"
      end)
    else
      value
    end
  end

  defp strip_dangerous_markdown_html(text) do
    text
    |> String.replace(~r/<(script|style)\b[^>]*>.*?<\/\1>/is, "")
    |> String.replace(~r/<(script|style)\b[^>]*>.*\z/is, "")
    |> String.replace(~r/<\/(script|style)\s*>/i, "")
  end

  defp escape_markdown_html(text) do
    text |> HtmlEntities.decode() |> escape_html()
  end

  defp escape_html(text) do
    {:safe, escaped} = Phoenix.HTML.html_escape(text)
    escaped
  end

  def html_escape({text, mentions, hashtags}, type) do
    {html_escape(text, type), mentions, hashtags}
  end

  def html_escape(text, "text/html") do
    HTML.filter_tags(text)
  end

  def html_escape(text, "text/x.misskeymarkdown") do
    HTML.filter_tags(text)
  end

  def html_escape(text, "text/plain") do
    Regex.split(@link_regex, text, include_captures: true)
    |> Enum.map_every(2, fn chunk ->
      {:safe, part} = Phoenix.HTML.html_escape(chunk)
      part
    end)
    |> Enum.join("")
  end

  def truncate(text, max_length \\ 200, omission \\ "...") do
    # Remove trailing whitespace
    text = Regex.replace(~r/([^ \t\r\n])([ \t]+$)/u, text, "\\g{1}")

    if String.length(text) < max_length do
      text
    else
      length_with_omission = max_length - String.length(omission)
      String.slice(text, 0, length_with_omission) <> omission
    end
  end

  defp get_nickname_text(nickname, %{mentions_format: :full}), do: User.full_nickname(nickname)
  defp get_nickname_text(nickname, _), do: User.local_nickname(nickname)
end
