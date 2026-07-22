# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Formatter do
  alias Pleroma.HTML
  alias Pleroma.User

  @safe_mention_regex ~r/^(\s*(?<mentions>(@.+?\s+){1,})+)(?<rest>.*)/s
  @link_regex ~r"((?:http(s)?:\/\/)?[\w.-]+(?:\.[\w\.-]+)+[\w\-\._~%:/?#[\]@!\$&'\(\)\*\+,;=.]+)|[0-9a-z+\-\.]+:[0-9a-z$-_.+!*'(),]+"ui
  @markdown_characters_regex ~r/(`|\*|_|{|}|[|]|\(|\)|#|\+|-|\.|!)/

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
    strip_email_autolinks = Map.get(opts, :strip_email_autolinks, false)
    text = normalize_markdown_quirks(text)

    MDEx.new(
      markdown: text,
      extension: [autolink: true, strikethrough: true],
      parse: [smart: false],
      render: [hardbreaks: breaks, unsafe: true]
    )
    |> MDEx.Document.run()
    |> maybe_strip_email_autolinks(strip_email_autolinks)
    |> MDEx.Document.update_nodes(MDEx.HtmlBlock, &strip_dangerous_raw_html/1)
    |> MDEx.Document.update_nodes(MDEx.HtmlInline, &strip_dangerous_raw_html/1)
    |> MDEx.to_html!()
    |> compact_markdown_html(text)
  end

  defp compact_markdown_html(html, markdown) do
    html
    |> String.trim_trailing("\n")
    |> String.replace(~r/>\n\s*</, "><")
    |> String.replace(~r/\n<\/code><\/pre>/, "</code></pre>")
    |> String.replace(~r/(?<!<pre>)<code>/, ~s(<code class="inline">))
    |> String.replace("<hr />", "<hr/>")
    |> unwrap_raw_html_paragraph(markdown)
  end

  defp normalize_markdown_quirks(text) do
    String.replace(text, ~r/~~([^~\n]+)~~~/, "~~\\1~~\\\\~")
  end

  defp unwrap_raw_html_paragraph(html, markdown) do
    if inline_raw_html_only?(markdown) do
      String.replace(html, ~r/\A<p>(.*)<\/p>\z/s, "\\1")
    else
      html
    end
  end

  defp inline_raw_html_only?(markdown) do
    markdown = String.trim(markdown)

    String.match?(
      markdown,
      ~r/\A(?:<!--|<\/?(?:a|abbr|acronym|b|bdi|bdo|big|br|cite|code|data|del|dfn|em|i|img|ins|kbd|mark|q|rb|rp|rt|rtc|ruby|s|samp|small|span|strong|sub|sup|time|tt|u|var|wbr)(?:\s|>|\/>))/i
    ) &&
      String.ends_with?(markdown, ">")
  end

  defp maybe_strip_email_autolinks(document, true) do
    MDEx.Document.update_nodes(document, MDEx.Link, &strip_email_autolink/1)
  end

  defp maybe_strip_email_autolinks(document, _), do: document

  defp strip_email_autolink(
         %MDEx.Link{
           nodes: [%MDEx.Text{literal: literal, sourcepos: text_sourcepos} = text],
           url: "mailto:" <> email,
           sourcepos: sourcepos
         } = link
       ) do
    if email == literal and sourcepos == text_sourcepos, do: text, else: link
  end

  defp strip_email_autolink(link), do: link

  defp strip_dangerous_raw_html(%{literal: literal} = node) do
    literal =
      literal
      |> String.replace(~r/<(script|style)\b[^>]*>.*?<\/\1>/is, "")
      |> String.replace(~r/<(script|style)\b[^>]*>.*\z/is, "")
      |> String.replace(~r/<\/(script|style)\s*>/i, "")

    %{node | literal: literal}
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
