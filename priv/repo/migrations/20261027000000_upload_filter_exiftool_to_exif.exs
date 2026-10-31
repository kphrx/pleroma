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

  # Only touch configs that list filters: adding an empty list would hide the
  # filters from the config file.
  defp rename_filters(renames) do
    with %{value: value} <- ConfigDB.get_by_params(%{group: :pleroma, key: Pleroma.Upload}),
         filters when is_list(filters) <- value[:filters],
         new_filters when new_filters != filters <-
           filters |> Enum.map(&Map.get(renames, &1, &1)) |> Enum.uniq() do
      ConfigDB.update_or_create(%{
        group: :pleroma,
        key: Pleroma.Upload,
        value: Keyword.put(value, :filters, new_filters)
      })
    else
      _ -> nil
    end
  end
end
