# Pleroma: A lightweight social networking server
# Copyright © 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.FollowRequestController do
  use Pleroma.Web, :controller

  import Pleroma.Web.ControllerHelper,
    only: [add_link_headers: 2]

  alias Pleroma.Pagination
  alias Pleroma.User
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(Pleroma.Web.ApiSpec.CastAndValidate, replace_params: false)

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  plug(OAuthScopesPlug, %{scopes: ["follow", "read:follows"]})

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.PleromaFollowRequestOperation

  @doc "GET /api/v1/pleroma/outgoing_follow_requests"
  def outgoing(%{assigns: %{user: follower}} = conn, params) do
    follow_requests =
      follower
      |> User.get_outgoing_follow_requests_query()
      |> Pagination.fetch_paginated(params, :keyset, :following)

    conn
    |> put_view(Pleroma.Web.MastodonAPI.FollowRequestView)
    |> add_link_headers(follow_requests)
    |> render("index.json", for: follower, users: follow_requests, as: :user)
  end
end
