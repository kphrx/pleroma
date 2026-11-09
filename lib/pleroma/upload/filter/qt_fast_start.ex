# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.QtFastStart do
  @moduledoc """
  Converts a "slow start" MP4/MOV file to a "fast start" file by relocating
  the moov atom (metadata) before the mdat atom (media data) and updating
  chunk offset references.

  This enables video playback to start before the entire file is downloaded.
  """

  @behaviour Pleroma.Upload.Filter

  @spec filter(Pleroma.Upload.t()) ::
          {:ok, :filtered} | {:ok, :noop} | {:error, String.t()}
  def filter(%Pleroma.Upload{tempfile: file, content_type: "video" <> _} = _upload) do
    try do
      binary = File.read!(file)
      result = Pleroma.Helpers.QtFastStart.fix(binary)

      if result != binary do
        File.write!(file, result)
        {:ok, :filtered}
      else
        {:ok, :noop}
      end
    rescue
      e -> {:error, "#{__MODULE__}: #{inspect(e)}"}
    end
  end

  def filter(_), do: {:ok, :noop}
end
