# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.Exif.ReadDescription do
  @moduledoc """
  Reads a description from image metadata when the upload has none yet.

  Checks EXIF ImageDescription, then IPTC Caption-Abstract, then XMP. Blank
  values and values longer than `[:instance, :description_limit]` are ignored.
  """

  @behaviour Pleroma.Upload.Filter

  @impl true
  def filter(%Pleroma.Upload{description: description}) when is_binary(description),
    do: {:ok, :noop}

  def filter(%Pleroma.Upload{tempfile: file, content_type: "image" <> _} = upload) do
    max_length = Pleroma.Config.get([:instance, :description_limit])

    case ExifStripper.Description.read_file(file, max_length: max_length) do
      description when is_binary(description) ->
        {:ok, :filtered, %{upload | description: description}}

      nil ->
        {:ok, :noop}
    end
  end

  def filter(_), do: {:ok, :noop}
end
