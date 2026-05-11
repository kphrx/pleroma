# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.UtilView do
  use Pleroma.Web, :view
  alias Pleroma.Config

  def render("frontend_configurations.json", _) do
    Config.get(:frontend_configurations, %{})
    |> Enum.into(%{})
  end
end
