# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.Exif.StripLocationTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Tests.ExifHelpers

  alias Pleroma.Upload.Filter.Exif.StripLocation

  for {fixture, content_type} <- [
        {"DSCN0010.jpg", "image/jpeg"},
        {"DSCN0010.png", "image/png"},
        {"strip_location_gps.webp", "image/webp"},
        {"strip_location_gps.heic", "image/heic"},
        {"strip_location_gps_grid.heic", "image/heic"},
        {"strip_location_gps.tiff", "image/tiff"}
      ] do
    test "strips GPS data from #{fixture} (#{content_type})" do
      upload = upload_copy(unquote(fixture), unquote(content_type))
      assert gps_tags(upload.tempfile) =~ "GPS Latitude"

      assert StripLocation.filter(upload) == {:ok, :filtered}
      assert gps_tags(upload.tempfile) == ""
    end
  end

  test "strips GPS data from XMP, including DJI drone positions" do
    for fixture <- ["xmp_gps.jpg", "dji_gps.jpg"] do
      upload = upload_copy(fixture, "image/jpeg")
      assert exiftool_xmp(upload.tempfile) =~ "GPSLatitude"

      assert StripLocation.filter(upload) == {:ok, :filtered}
      refute exiftool_xmp(upload.tempfile) =~ ~r/GPS|AbsoluteAltitude/
    end
  end

  defp exiftool_xmp(path) do
    {output, 0} = System.cmd("exiftool", ["-m", "-s", "-xmp:all", path])
    output
  end

  test "keeps other EXIF data in HEIC" do
    upload = upload_copy("strip_location_gps.heic", "image/heic")

    assert StripLocation.filter(upload) == {:ok, :filtered}
    assert tag(upload.tempfile, "ImageDescription") == "a heic with a location"
    assert tag(upload.tempfile, "ImageSize") == "64x48"
  end

  test "does nothing when there is no GPS data" do
    upload = upload_copy("image.jpg", "image/jpeg")
    original = File.read!(upload.tempfile)

    assert StripLocation.filter(upload) == {:ok, :noop}
    assert File.read!(upload.tempfile) == original
  end

  test "accepts PNG files with data after IEND" do
    upload = upload_copy("image_with_stray_data_after.png", "image/png")

    assert {:ok, _} = StripLocation.filter(upload)
  end

  test "ignores non-image uploads" do
    upload = upload_copy("DSCN0010.jpg", "application/octet-stream")

    assert StripLocation.filter(upload) == {:ok, :noop}
    assert gps_tags(upload.tempfile) =~ "GPS Latitude"
  end
end
