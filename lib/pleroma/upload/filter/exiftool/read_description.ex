# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.Exiftool.ReadDescription do
  @moduledoc """
  Deprecated: use `Pleroma.Upload.Filter.Exif.ReadDescription`. This module delegates to it.
  """

  @behaviour Pleroma.Upload.Filter

  @impl true
  defdelegate filter(upload), to: Pleroma.Upload.Filter.Exif.ReadDescription
end
