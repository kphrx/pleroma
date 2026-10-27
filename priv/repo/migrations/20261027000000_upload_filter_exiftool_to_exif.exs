# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.UploadFilterExiftoolToExif do
  use Ecto.Migration

  alias Pleroma.ConfigDB

  @up %{
    Pleroma.Upload.Filter.Exiftool => Pleroma.Upload.Filter.Exif.StripLocation,
    Pleroma.Upload.Filter.Exiftool.StripLocation => Pleroma.Upload.Filter.Exif.StripLocation,
    Pleroma.Upload.Filter.Exiftool.ReadDescription => Pleroma.Upload.Filter.Exif.ReadDescription
  }

  @down %{
    Pleroma.Upload.Filter.Exif.StripLocation => Pleroma.Upload.Filter.Exiftool.StripLocation,
    Pleroma.Upload.Filter.Exif.ReadDescription => Pleroma.Upload.Filter.Exiftool.ReadDescription
  }

  def up, do: rename_filters(@up)

  def down, do: rename_filters(@down)

  defp rename_filters(renames) do
    case ConfigDB.get_by_params(%{group: :pleroma, key: Pleroma.Upload}) do
      %{value: value} ->
        new_value =
          Keyword.update(value, :filters, [], fn filters ->
            filters
            |> Enum.map(&Map.get(renames, &1, &1))
            |> Enum.uniq()
          end)

        ConfigDB.update_or_create(%{group: :pleroma, key: Pleroma.Upload, value: new_value})

      _ ->
        nil
    end
  end
end
