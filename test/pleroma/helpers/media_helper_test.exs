# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.MediaHelperTest do
  use ExUnit.Case, async: true

  alias Pleroma.Helpers.MediaHelper

  # a RIFF/WEBP header with a first chunk and its first payload byte
  defp webp(chunk, first_byte) do
    payload = <<first_byte, 0::size(72)>>

    "RIFF" <>
      <<byte_size(payload) + 12::little-32>> <> "WEBP" <> chunk <> <<10::little-32>> <> payload
  end

  describe "animated_webp?/1" do
    test "is true for an animated WebP" do
      assert MediaHelper.animated_webp?(File.read!("test/fixtures/animated.webp"))
    end

    test "is false for a still lossy WebP (VP8)" do
      refute MediaHelper.animated_webp?(File.read!("test/fixtures/still.webp"))
    end

    test "is false for a still lossless WebP (VP8L)" do
      refute MediaHelper.animated_webp?(webp("VP8L", 0x02))
    end

    test "is false for a VP8X WebP without the animation flag" do
      # alpha only
      refute MediaHelper.animated_webp?(webp("VP8X", 0x10))
    end

    test "is true for a VP8X WebP with the animation flag" do
      assert MediaHelper.animated_webp?(webp("VP8X", 0x02))
    end

    test "is false for other files" do
      refute MediaHelper.animated_webp?(File.read!("test/fixtures/image.gif"))
      refute MediaHelper.animated_webp?(File.read!("test/fixtures/image.png"))
    end

    test "is false for short or empty binaries" do
      refute MediaHelper.animated_webp?("")
      refute MediaHelper.animated_webp?("RIFF")
      refute MediaHelper.animated_webp?(binary_part(webp("VP8X", 0x02), 0, 20))
    end
  end

  describe "image_resize/2" do
    @url "https://example.com/animated.webp"
    @options %{max_width: 32, max_height: 32, quality: 85}

    setup do
      Tesla.Mock.mock(fn %{method: :get, url: @url} ->
        %Tesla.Env{status: 200, body: File.read!("test/fixtures/animated.webp")}
      end)

      :ok
    end

    test "does not resize an animated WebP" do
      assert {:error, :animated} = MediaHelper.image_resize(@url, @options)
    end

    test "with `still: true`, resizes the first frame of an animated WebP" do
      assert {:ok, <<0xFF, 0xD8, _::binary>>} =
               MediaHelper.image_resize(@url, Map.put(@options, :still, true))
    end
  end
end
