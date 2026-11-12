# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AttachmentValidatorTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.UnstubbedConfigMock, as: ConfigMock
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.ObjectValidators.AttachmentValidator
  alias Pleroma.Web.ActivityPub.Transmogrifier

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

      assert attachment.mediaType == "image/jpeg"
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

    test "it guesses a missing media type from the url extension (Threads)" do
      attachment = %{
        "type" => "Image",
        "url" => "https://cdn.example.com/v/t51/900924821_n.webp?stp=dst-jpg_e35&oh=00_AQ",
        "width" => 2000,
        "height" => 1500
      }

      {:ok, attachment} =
        AttachmentValidator.cast_and_validate(attachment)
        |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "image/webp"
      assert [%{mediaType: "image/webp", width: 2000, height: 1500}] = attachment.url
    end

    test "it guesses a missing media type of a url link object" do
      attachment = %{
        "type" => "Document",
        "url" => [%{"type" => "Link", "href" => "https://example.com/clip.mp4"}]
      }

      {:ok, attachment} =
        AttachmentValidator.cast_and_validate(attachment)
        |> Ecto.Changeset.apply_action(:insert)

      assert [%{mediaType: "video/mp4"}] = attachment.url
    end

    test "it falls back to the object type for a missing media type" do
      for {type, expected} <- [{"Image", "image/*"}, {"Video", "video/*"}, {"Audio", "audio/*"}] do
        attachment = %{"type" => type, "url" => "https://example.com/media/12345"}

        {:ok, attachment} =
          AttachmentValidator.cast_and_validate(attachment)
          |> Ecto.Changeset.apply_action(:insert)

        assert attachment.mediaType == expected
        assert [%{mediaType: ^expected}] = attachment.url
      end
    end

    test "it uses the guessed media type for url links of incoming objects" do
      for {url, expected} <- [
            {"https://cdn.example.com/a_n.webp?stp=1", "image/webp"},
            {"https://example.com/media/12345", "image/*"}
          ] do
        %{"attachment" => [attachment]} =
          Transmogrifier.fix_attachments(%{"attachment" => [%{"type" => "Image", "url" => url}]})

        {:ok, attachment} =
          AttachmentValidator.cast_and_validate(attachment)
          |> Ecto.Changeset.apply_action(:insert)

        assert attachment.mediaType == expected
        assert [%{mediaType: ^expected}] = attachment.url
      end
    end

    test "it guesses only image, video or audio media types" do
      for url <- ["https://example.com/page.html", "https://example.com/doc.pdf"] do
        attachment = %{"type" => "Document", "url" => url}

        {:ok, attachment} =
          AttachmentValidator.cast_and_validate(attachment)
          |> Ecto.Changeset.apply_action(:insert)

        assert attachment.mediaType == "application/octet-stream"
      end
    end

    test "it uses mimeType when mediaType is empty or unknown" do
      for media_type <- ["", "application/octet-stream"] do
        attachment = %{
          "type" => "Document",
          "mediaType" => media_type,
          "mimeType" => "image/png",
          "url" => "https://example.com/image.jpg"
        }

        {:ok, attachment} =
          AttachmentValidator.cast_and_validate(attachment)
          |> Ecto.Changeset.apply_action(:insert)

        assert attachment.mediaType == "image/png"
      end
    end

    test "it keeps a media type sent by the remote" do
      attachment = %{
        "type" => "Image",
        "mediaType" => "image/png",
        "url" => "https://example.com/image.jpg"
      }

      {:ok, attachment} =
        AttachmentValidator.cast_and_validate(attachment)
        |> Ecto.Changeset.apply_action(:insert)

      assert attachment.mediaType == "image/png"
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
  end
end
