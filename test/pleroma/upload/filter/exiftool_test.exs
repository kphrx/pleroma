# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.ExiftoolTest do
  # Instances may still configure the deprecated Exiftool filter names.
  # They must keep working, including for formats exiftool used to skip.
  use Pleroma.DataCase, async: true

  import Pleroma.Tests.ExifHelpers

  for filter <- [Pleroma.Upload.Filter.Exiftool, Pleroma.Upload.Filter.Exiftool.StripLocation] do
    test "#{inspect(filter)} strips GPS data from HEIC uploads" do
      upload = upload_copy("strip_location_gps.heic", "image/heic")
      assert gps_tags(upload.tempfile) =~ "GPS Latitude"

      assert Pleroma.Upload.Filter.filter([unquote(filter)], upload) == {:ok, upload}
      assert gps_tags(upload.tempfile) == ""
    end
  end

  test "Exiftool.ReadDescription reads the description" do
    upload = upload_copy("strip_location_gps.heic", "image/heic", description: nil)

    assert {:ok, %{description: "a heic with a location"}} =
             Pleroma.Upload.Filter.filter(
               [Pleroma.Upload.Filter.Exiftool.ReadDescription],
               upload
             )
  end
end
