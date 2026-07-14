# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AttachmentValidatorTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.UnstubbedConfigMock, as: ConfigMock
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.ObjectValidators.AttachmentValidator

  import Mox
  import Pleroma.Factory

  describe "attachments" do
    test "works with apng" do
      attachment =
        %{
          "mediaType" => "image/apng",
          "name" => "",
          "type" => "Document",
          "url" =>
            "https://media.misskeyusercontent.com/io/2859c26e-cd43-4550-848b-b6243bc3fe28.apng"
        }

      assert {:ok, attachment} =
               AttachmentValidator.cast_and_validate(attachment)
               |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "image/apng"
    end

    test "fails without url" do
      attachment = %{
        "mediaType" => "",
        "name" => "",
        "summary" => "298p3RG7j27tfsZ9RQ.jpg",
        "type" => "Document"
      }

      assert {:error, _cng} =
               AttachmentValidator.cast_and_validate(attachment)
               |> Ecto.Changeset.apply_action(:insert)
    end

    test "works with honkerific attachments" do
      honk = %{
        "mediaType" => "",
        "summary" => "Select your spirit chonk",
        "name" => "298p3RG7j27tfsZ9RQ.jpg",
        "type" => "Document",
        "url" => "https://honk.tedunangst.com/d/298p3RG7j27tfsZ9RQ.jpg"
      }

      assert {:ok, attachment} =
               honk
               |> AttachmentValidator.cast_and_validate()
               |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "application/octet-stream"
      assert attachment.summary == "Select your spirit chonk"
      assert attachment.name == "298p3RG7j27tfsZ9RQ.jpg"
    end

    test "works with an unknown but valid mime type" do
      attachment = %{
        "mediaType" => "x-custom/x-type",
        "type" => "Document",
        "url" => "https://example.org"
      }

      assert {:ok, attachment} =
               AttachmentValidator.cast_and_validate(attachment)
               |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "x-custom/x-type"
    end

    test "works with invalid mime types" do
      attachment = %{
        "mediaType" => "x-customx-type",
        "type" => "Document",
        "url" => "https://example.org"
      }

      assert {:ok, attachment} =
               AttachmentValidator.cast_and_validate(attachment)
               |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "application/octet-stream"

      attachment = %{
        "mediaType" => "https://example.org",
        "type" => "Document",
        "url" => "https://example.org"
      }

      assert {:ok, attachment} =
               AttachmentValidator.cast_and_validate(attachment)
               |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "application/octet-stream"
    end

    test "it turns mastodon attachments into our attachments" do
      attachment = %{
        "url" =>
          "http://mastodon.example.org/system/media_attachments/files/000/000/002/original/334ce029e7bfb920.jpg",
        "type" => "Document",
        "name" => nil,
        "mediaType" => "image/jpeg",
        "blurhash" => "UD9jJz~VSbR#xT$~%KtQX9R,WAs9RjWBs:of"
      }

      {:ok, attachment} =
        AttachmentValidator.cast_and_validate(attachment)
        |> Ecto.Changeset.apply_action(:insert)

      assert [
               %{
                 href:
                   "http://mastodon.example.org/system/media_attachments/files/000/000/002/original/334ce029e7bfb920.jpg",
                 type: "Link",
                 mediaType: "image/jpeg"
               }
             ] = attachment.url

      assert attachment.mediaType == "image/jpeg"
      assert attachment.blurhash == "UD9jJz~VSbR#xT$~%KtQX9R,WAs9RjWBs:of"
    end

    test "it handles our own uploads" do
      user = insert(:user)

      file = %Plug.Upload{
        content_type: "image/jpeg",
        path: Path.absname("test/fixtures/image.jpg"),
        filename: "an_image.jpg"
      }

      ConfigMock
      |> stub_with(Pleroma.Test.StaticConfig)

      {:ok, attachment} = ActivityPub.upload(file, actor: user.ap_id)

      {:ok, attachment} =
        attachment.data
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "image/jpeg"
    end

    test "it handles image dimensions" do
      attachment = %{
        "url" => [
          %{
            "type" => "Link",
            "mediaType" => "image/jpeg",
            "href" => "https://example.com/images/1.jpg",
            "width" => 200,
            "height" => 100
          }
        ],
        "type" => "Document",
        "name" => nil,
        "mediaType" => "image/jpeg"
      }

      {:ok, attachment} =
        AttachmentValidator.cast_and_validate(attachment)
        |> Ecto.Changeset.apply_action(:insert)

      assert [
               %{
                 href: "https://example.com/images/1.jpg",
                 type: "Link",
                 mediaType: "image/jpeg",
                 width: 200,
                 height: 100
               }
             ] = attachment.url

      assert attachment.mediaType == "image/jpeg"
    end

    test "it transforms image dimensions to our internal format" do
      attachment = %{
        "type" => "Document",
        "name" => "Hello world",
        "url" => "https://media.example.tld/1.jpg",
        "width" => 880,
        "height" => 960,
        "mediaType" => "image/jpeg",
        "blurhash" => "eTKL26+HDjcEIBVl;ds+K6t301W.t7nit7y1E,R:v}ai4nXSt7V@of"
      }

      expected = %AttachmentValidator{
        type: "Document",
        name: "Hello world",
        mediaType: "image/jpeg",
        blurhash: "eTKL26+HDjcEIBVl;ds+K6t301W.t7nit7y1E,R:v}ai4nXSt7V@of",
        url: [
          %AttachmentValidator.UrlObjectValidator{
            type: "Link",
            mediaType: "image/jpeg",
            href: "https://media.example.tld/1.jpg",
            width: 880,
            height: 960
          }
        ]
      }

      {:ok, ^expected} =
        AttachmentValidator.cast_and_validate(attachment)
        |> Ecto.Changeset.apply_action(:insert)
    end

    test "sniffs image/jpeg for octet-stream attachments whose body is an image" do
      url = "https://example.com/media/no-extension/original"
      jpeg = File.read!("test/fixtures/image.jpg")

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: jpeg}
      end)

      attachment = %{
        "type" => "Document",
        "mediaType" => "application/octet-stream",
        "url" => [%{"type" => "Link", "href" => url, "mediaType" => "application/octet-stream"}]
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert [%{href: ^url, mediaType: "image/jpeg"}] = attachment.url
    end

    test "sniffs image/jpeg for attachments with a missing mediaType" do
      url = "https://example.com/media/missing-type/original"
      jpeg = File.read!("test/fixtures/image.jpg")

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: jpeg}
      end)

      attachment = %{
        "type" => "Document",
        "url" => [%{"type" => "Link", "href" => url}]
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert [%{href: ^url, mediaType: "image/jpeg"}] = attachment.url
    end

    test "leaves non-image octet-stream attachments as octet-stream" do
      url = "https://example.com/media/some-document"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: "just some plain text, not an image at all"}
      end)

      attachment = %{
        "type" => "Document",
        "mediaType" => "application/octet-stream",
        "url" => [%{"type" => "Link", "href" => url, "mediaType" => "application/octet-stream"}]
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert [%{mediaType: "application/octet-stream"}] = attachment.url
    end

    test "does not sniff when the remote already provided a real mediaType" do
      # No Tesla mock is set up: if the validator tried to fetch, Tesla.Mock
      # would raise and fail the test. A real image type must be kept as-is.
      attachment = %{
        "type" => "Document",
        "mediaType" => "image/png",
        "url" => [
          %{"type" => "Link", "href" => "https://example.com/x", "mediaType" => "image/png"}
        ]
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert [%{mediaType: "image/png"}] = attachment.url
    end
  end

  describe "fix_media_type fallbacks and sniffing" do
    test "uses mimeType as a fallback when mediaType is absent (real type, not sniffed)" do
      # No Tesla mock: if the validator tried to fetch, the test would fail.
      # A real image type coming from mimeType must be preserved as-is on the
      # outer attachment and on the synthesised url entry (string url form).
      attachment = %{
        "type" => "Document",
        "mimeType" => "image/png",
        "url" => "https://example.com/x.png"
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "image/png"
      assert [%{mediaType: "image/png"}] = attachment.url
    end

    test "prefers mediaType over mimeType when both are present" do
      attachment = %{
        "type" => "Document",
        "mediaType" => "image/gif",
        "mimeType" => "image/png",
        "url" => "https://example.com/x.gif"
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "image/gif"
      assert [%{mediaType: "image/gif"}] = attachment.url
    end

    test "sniffs when the url entry's mediaType is application/octet-stream and the body is an image" do
      # The outer attachment mediaType is not sniffed (no top-level href); only
      # the url entry is. We assert only on the url entry.
      url = "https://example.com/media/mime-type-octet"
      jpeg = File.read!("test/fixtures/image.jpg")

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: jpeg}
      end)

      attachment = %{
        "type" => "Document",
        "mediaType" => "application/octet-stream",
        "url" => [%{"type" => "Link", "href" => url, "mediaType" => "application/octet-stream"}]
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert [%{mediaType: "image/jpeg"}] = attachment.url
    end

    test "sniffs when mediaType is the empty string and the body is an image" do
      url = "https://example.com/media/empty-mediatype"
      png = File.read!("test/fixtures/image.png")

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 200, body: png}
      end)

      attachment = %{
        "type" => "Document",
        "mediaType" => "",
        "url" => [%{"type" => "Link", "href" => url, "mediaType" => ""}]
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert [%{mediaType: "image/png"}] = attachment.url
    end

    test "falls back to the declared type when the sniffer HTTP request fails" do
      url = "https://example.com/media/sniff-404"

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        %Tesla.Env{status: 404, body: ""}
      end)

      attachment = %{
        "type" => "Document",
        "mediaType" => "application/octet-stream",
        "url" => [%{"type" => "Link", "href" => url, "mediaType" => "application/octet-stream"}]
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert [%{mediaType: "application/octet-stream"}] = attachment.url
    end

    test "sniffs each url entry independently" do
      jpeg_url = "https://example.com/media/a"
      octet_url = "https://example.com/media/b"
      jpeg = File.read!("test/fixtures/image.jpg")

      Tesla.Mock.mock(fn
        %{method: :get, url: ^jpeg_url} ->
          %Tesla.Env{status: 200, body: jpeg}

        %{method: :get, url: ^octet_url} ->
          %Tesla.Env{status: 200, body: "definitely not an image"}
      end)

      attachment = %{
        "type" => "Document",
        "mediaType" => "application/octet-stream",
        "url" => [
          %{"type" => "Link", "href" => jpeg_url, "mediaType" => "application/octet-stream"},
          %{"type" => "Link", "href" => octet_url, "mediaType" => "application/octet-stream"}
        ]
      }

      {:ok, attachment} =
        attachment
        |> AttachmentValidator.cast_and_validate()
        |> Ecto.Changeset.apply_action(:insert)

      assert [
               %{href: ^jpeg_url, mediaType: "image/jpeg"},
               %{href: ^octet_url, mediaType: "application/octet-stream"}
             ] = attachment.url
    end
  end
end
