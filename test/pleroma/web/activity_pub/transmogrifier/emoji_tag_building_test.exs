defmodule Pleroma.Web.ActivityPub.Transmogrifier.EmojiTagBuildingTest do
  use Pleroma.DataCase, async: true

  test "it encodes the id to be a valid url" do
    name = "hanapog"
    url = "https://misskey.local.live/emojis/hana pog.png"

    tag = Pleroma.Emoji.build_emoji_tag({name, url})

    assert tag["id"] == "https://misskey.local.live/emojis/hana%20pog.png"
  end

  test "it does not double-encode already encoded urls" do
    name = "hanapog"
    url = "https://misskey.local.live/emojis/hana%20pog.png"

    tag = Pleroma.Emoji.build_emoji_tag({name, url})

    assert tag["id"] == url
  end

  test "it encodes disallowed path characters" do
    name = "hanapog"
    url = "https://example.com/emojis/hana[pog].png"

    tag = Pleroma.Emoji.build_emoji_tag({name, url})

    assert tag["id"] == "https://example.com/emojis/hana%5Bpog%5D.png"
  end

  test "local_url does not decode percent in filenames" do
    url = Pleroma.Emoji.local_url("/emoji/hana%20pog.png")

    assert url == Pleroma.Web.Endpoint.url() <> "/emoji/hana%2520pog.png"

    tag = Pleroma.Emoji.build_emoji_tag({"hanapog", url})

    assert tag["id"] == url
  end
end
