# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.TokenView do
  use Pleroma.Web, :view

  def render("index.json", %{tokens: tokens}) do
    tokens
    |> render_many(Pleroma.Web.OAuth.TokenView, "show.json")
    |> Enum.filter(&Enum.any?/1)
  end

  def render("show.json", %{token: token_entry}) do
    %{
      id: token_entry.id,
      valid_until: token_entry.valid_until,
      app_name: token_entry.app.client_name,
      scopes: token_entry.scopes
    }
  end
end
