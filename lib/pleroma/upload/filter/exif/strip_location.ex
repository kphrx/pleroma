# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.Exif.StripLocation do
  @moduledoc """
  Strips GPS metadata from uploaded images and overwrites the file in place.

  Supports JPEG, PNG, WebP, TIFF and ISO-BMFF images (HEIC, AVIF). This is lossless:
  the image data is not re-encoded. Other image types are left untouched.
  """

  @behaviour Pleroma.Upload.Filter

  @impl true
  def filter(%Pleroma.Upload{tempfile: file, content_type: "image" <> _}) do
    case ExifStripper.GpsStripper.strip_gps_data(file, file) do
      :ok -> {:ok, :filtered}
      :noop -> {:ok, :noop}
      {:error, _} = error -> error
    end
  end

  def filter(_), do: {:ok, :noop}
end
