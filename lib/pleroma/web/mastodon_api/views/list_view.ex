# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.ListView do
  use Pleroma.Web, :view

  alias Pleroma.Emoji
  alias Pleroma.Web.MastodonAPI.ListView

  def render("index.json", %{lists: lists} = opts) do
    render_many(lists, ListView, "show.json", opts)
  end

  def render("show.json", %{list: list}) do
    {emoji, emoji_url} = get_emoji(list.emoji)

    %{
      id: to_string(list.id),
      title: list.title,
      exclusive: list.exclusive,
      pleroma: %{
        emoji: emoji,
        emoji_url: emoji_url
      }
    }
  end

  defp get_emoji(nil), do: {nil, nil}

  defp get_emoji(emoji) do
    if Emoji.unicode?(emoji) do
      {emoji, nil}
    else
      case Emoji.get(emoji) do
        nil -> {nil, nil}
        emoji_data -> {emoji, Emoji.local_url(emoji_data.file)}
      end
    end
  end
end
