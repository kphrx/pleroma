# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AttachmentTypeSnifferTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.AttachmentTypeSniffer

  # @sniff_bytes must mirror the value in the module under test; we assert the
  # Range header that the sniffer sends, so the test should fail loudly if the
  # constant drifts.
  @sniff_bytes 8 * 1024
  @range_header "bytes=0-#{@sniff_bytes - 1}"

  describe "sniff_image_type/1 with a real image body" do
    test "returns image/jpeg for a JPEG body" do
      url = "https://example.com/media/image.jpg"
      jpeg = File.read!("test/fixtures/image.jpg")

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: jpeg}
      end)

      assert {:ok, "image/jpeg"} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns image/png for a PNG body" do
      url = "https://example.com/media/image.png"
      png = File.read!("test/fixtures/image.png")

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: png}
      end)

      assert {:ok, "image/png"} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns image/gif for a GIF body" do
      url = "https://example.com/media/image.gif"
      gif = File.read!("test/fixtures/image.gif")

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: gif}
      end)

      assert {:ok, "image/gif"} = AttachmentTypeSniffer.sniff_image_type(url)
    end
  end

  describe "sniff_image_type/1 sends a ranged request" do
    test "sends a Range header asking for the first chunk" do
      url = "https://example.com/media/ranged"
      jpeg = File.read!("test/fixtures/image.jpg")

      Tesla.Mock.mock(fn
        %{method: :get, url: ^url, headers: headers} ->
          headers_map = Enum.into(headers, %{})
          assert headers_map["range"] == @range_header

          %Tesla.Env{status: 200, body: jpeg}

        %{method: :get, url: ^url} ->
          # If the sniffer did not send the Range header, fail explicitly.
          flunk("expected Range header to be sent with the request")
      end)

      assert {:ok, "image/jpeg"} = AttachmentTypeSniffer.sniff_image_type(url)
    end
  end

  describe "sniff_image_type/1 with a non-image body" do
    test "returns nil for plain text" do
      url = "https://example.com/media/note.txt"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: "just some plain text, not an image at all"}
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns nil for an HTML body" do
      url = "https://example.com/page"
      html = File.read!("test/fixtures/rel_me_anchor.html")

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: html}
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns nil for an empty body" do
      url = "https://example.com/media/empty"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: ""}
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns nil for a nil body" do
      url = "https://example.com/media/nil-body"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: nil}
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end
  end

  describe "sniff_image_type/1 on HTTP failure" do
    test "returns nil on a 404" do
      url = "https://example.com/media/missing"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 404, body: ""}
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns nil on a 500" do
      url = "https://example.com/media/oops"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 500, body: "server error"}
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns nil on a 3xx (not in 200..299)" do
      url = "https://example.com/media/redirect"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 302, body: ""}
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns nil on a transport-level error" do
      url = "https://example.com/media/econnrefused"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        {:error, :econnrefused}
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end

    test "returns nil when the HTTP adapter raises" do
      url = "https://example.com/media/raises"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        raise "boom"
      end)

      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(url)
    end
  end

  describe "sniff_image_type/1 guard clauses" do
    test "returns nil for nil input without making a request" do
      # No Tesla mock is configured; if a request were made, Tesla.Mock would
      # raise and fail the test.
      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type(nil)
    end

    test "returns nil for an empty-string URL without making a request" do
      assert {:ok, nil} = AttachmentTypeSniffer.sniff_image_type("")
    end
  end
end
