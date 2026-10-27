# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.UploadFilterExiftoolToExifTest do
  use Pleroma.DataCase
  import Pleroma.Factory
  import Pleroma.Tests.Helpers
  alias Pleroma.ConfigDB

  setup_all do: require_migration("20261027000000_upload_filter_exiftool_to_exif")

  defp filters do
    ConfigDB.get_by_params(%{group: :pleroma, key: Pleroma.Upload}).value[:filters]
  end

  test "up/0 renames the Exiftool filters", %{migration: migration} do
    insert(:config,
      group: :pleroma,
      key: Pleroma.Upload,
      value: [
        filters: [
          Pleroma.Upload.Filter.Dedupe,
          Pleroma.Upload.Filter.Exiftool,
          Pleroma.Upload.Filter.Exiftool.StripLocation,
          Pleroma.Upload.Filter.Exiftool.ReadDescription
        ]
      ]
    )

    migration.up()

    assert filters() == [
             Pleroma.Upload.Filter.Dedupe,
             Pleroma.Upload.Filter.Exif.StripLocation,
             Pleroma.Upload.Filter.Exif.ReadDescription
           ]
  end

  test "down/0 restores the Exiftool filters", %{migration: migration} do
    insert(:config,
      group: :pleroma,
      key: Pleroma.Upload,
      value: [
        filters: [
          Pleroma.Upload.Filter.Exif.StripLocation,
          Pleroma.Upload.Filter.Exif.ReadDescription
        ]
      ]
    )

    migration.down()

    assert filters() == [
             Pleroma.Upload.Filter.Exiftool.StripLocation,
             Pleroma.Upload.Filter.Exiftool.ReadDescription
           ]
  end

  test "up/0 does nothing without a database config", %{migration: migration} do
    assert migration.up() == nil
    assert ConfigDB.get_by_params(%{group: :pleroma, key: Pleroma.Upload}) == nil
  end
end
