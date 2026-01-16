# Pleroma: A lightweight social networking server
# Copyright © 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.BookmarkFolderView do
  use Pleroma.Web, :view

  alias Pleroma.BookmarkFolder
  alias Pleroma.Emoji

  def render("show.json", %{folder: %BookmarkFolder{} = folder}) do
    %{
      id: folder.id |> to_string(),
      name: folder.name,
      emoji: folder.emoji,
      emoji_url: get_emoji_url(folder.emoji)
    }
  end

  def render("index.json", %{folders: folders} = opts) do
    render_many(folders, __MODULE__, "show.json", Map.delete(opts, :folders))
  end

  defp get_emoji_url(nil) do
    nil
  end

  defp get_emoji_url(emoji) do
    if Emoji.unicode?(emoji) do
      nil
    else
      emoji = Emoji.get(emoji)

      if emoji != nil do
        Emoji.local_url(emoji.file)
      else
        nil
      end
    end
  end
end
