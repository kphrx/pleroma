# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.Exif.ReadDescriptionTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Upload.Filter.Exif.ReadDescription

  defp upload(fixture, attrs \\ []) do
    path = Path.absname(Path.join("test/fixtures", fixture))

    struct!(
      %Pleroma.Upload{
        name: fixture,
        content_type: "image/" <> String.trim_leading(Path.extname(fixture), "."),
        path: path,
        tempfile: path,
        description: nil
      },
      attrs
    )
  end

  test "keeps description when not empty" do
    upload =
      upload("image_with_imagedescription_and_caption-abstract.jpg",
        description: "Some description"
      )

    assert ReadDescription.filter(upload) == {:ok, :noop}
  end

  test "otherwise returns ImageDescription when present" do
    upload = upload("image_with_imagedescription_and_caption-abstract.jpg")

    assert ReadDescription.filter(upload) ==
             {:ok, :filtered, %{upload | description: "a descriptive white pixel"}}
  end

  test "ignores stray data after the image" do
    upload = upload("image_with_imagedescription_and_caption-abstract_and_stray_data_after.png")

    assert {:ok, :filtered, %{description: "a descriptive white pixel"}} =
             ReadDescription.filter(upload)

    assert ReadDescription.filter(upload("image_with_stray_data_after.png")) == {:ok, :noop}
  end

  test "otherwise returns iptc:Caption-Abstract when present" do
    upload = upload("image_with_caption-abstract.jpg")

    assert ReadDescription.filter(upload) ==
             {:ok, :filtered, %{upload | description: "an abstract white pixel"}}
  end

  test "reads ImageDescription from WebP and HEIC" do
    assert {:ok, :filtered, %{description: "a webp with a location"}} =
             ReadDescription.filter(upload("strip_location_gps.webp"))

    assert {:ok, :filtered, %{description: "a heic with a location"}} =
             ReadDescription.filter(upload("strip_location_gps.heic"))
  end

  test "does nothing when there is no description" do
    assert ReadDescription.filter(upload("image_with_no_description.jpg")) == {:ok, :noop}
  end

  test "ignores descriptions that exceed the maximum length" do
    clear_config([:instance, :description_limit], 5)

    upload = upload("image_with_imagedescription_and_caption-abstract.jpg")
    assert ReadDescription.filter(upload) == {:ok, :noop}
  end

  test "ignores content with only whitespace" do
    upload = upload("image_with_imagedescription_and_caption-abstract_whitespaces.jpg")
    assert ReadDescription.filter(upload) == {:ok, :noop}
  end

  test "does nothing when the file can't be read" do
    upload = %{upload("image.jpg") | tempfile: Path.absname("test/fixtures/non-existant_tmp.jpg")}
    assert ReadDescription.filter(upload) == {:ok, :noop}
  end
end
