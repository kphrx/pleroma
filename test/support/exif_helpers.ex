# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Tests.ExifHelpers do
  @moduledoc """
  Helpers for upload filter tests that use exiftool as an independent oracle.
  """

  @doc "Copies a fixture to a unique temporary file and returns an upload for it."
  def upload_copy(fixture, content_type, attrs \\ []) do
    source = Path.absname(Path.join("test/fixtures", fixture))

    tempfile =
      Path.join(
        System.tmp_dir!(),
        "pleroma_exif_#{System.unique_integer([:positive])}#{Path.extname(fixture)}"
      )

    File.cp!(source, tempfile)
    ExUnit.Callbacks.on_exit(fn -> File.rm(tempfile) end)

    struct!(
      %Pleroma.Upload{
        name: fixture,
        content_type: content_type,
        path: source,
        tempfile: tempfile
      },
      attrs
    )
  end

  @doc "Returns the GPS tags exiftool finds in a file, as text."
  def gps_tags(path), do: exiftool!(["-gps:all", path])

  @doc "Returns the value of one tag as exiftool reads it."
  def tag(path, tag), do: exiftool!(["-s3", "-#{tag}", path])

  defp exiftool!(args) do
    {output, 0} = System.cmd("exiftool", ["-m" | args])
    String.trim(output)
  end
end
