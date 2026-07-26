# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RemoteInteraction.RemoteInteractionView do
  use Pleroma.Web, :view
  import Phoenix.HTML
  import Phoenix.HTML.Form
  import Phoenix.HTML.Link
  alias Pleroma.Web.Gettext

  def avatar_url(user) do
    user
    |> Pleroma.User.avatar_url()
    |> Pleroma.Web.MediaProxy.url()
  end
end
