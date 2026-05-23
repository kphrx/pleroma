# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.NotificationController do
  use Pleroma.Web, :controller

  import Pleroma.Web.ControllerHelper, only: [add_link_headers: 2]

  alias Pleroma.Notification
  alias Pleroma.User
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.MastodonAPI.MastodonAPI
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  # Mastodon's docs currently list write:notifications for group accounts, but the endpoint is
  # read-only and Mastodon's implementation accepts read:notifications. Prefer least privilege.
  @oauth_read_actions [:show, :index, :grouped_index, :show_group, :group_accounts, :unread_count]

  plug(Pleroma.Web.ApiSpec.CastAndValidate, replace_params: false)

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:notifications"]} when action in @oauth_read_actions
  )

  plug(OAuthScopesPlug, %{scopes: ["write:notifications"]} when action not in @oauth_read_actions)

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.NotificationOperation

  @default_notification_types ~w{
      mention
      follow
      follow_request
      reblog
      favourite
      move
      pleroma:emoji_reaction
      poll
      update
      status
    }

  # GET /api/v1/notifications
  def index(%{private: %{open_api_spex: %{params: %{account_id: account_id} = params}}} = conn, _) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete(:account_id)
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_notifications(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def index(%{private: %{open_api_spex: %{params: params}}} = conn, _) do
    do_get_notifications(conn, params)
  end

  # GET /api/v2/notifications
  def grouped_index(
        %{private: %{open_api_spex: %{params: %{account_id: account_id} = params}}} = conn,
        _
      ) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete(:account_id)
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_grouped_notifications(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def grouped_index(%{private: %{open_api_spex: %{params: params}}} = conn, _) do
    do_get_grouped_notifications(conn, params)
  end

  # GET /api/v2/notifications/:group_key
  def show_group(
        %{assigns: %{user: user}, private: %{open_api_spex: %{params: %{group_key: group_key}}}} =
          conn,
        _
      ) do
    {notifications, notification_group_counts, notification_group_bounds} =
      MastodonAPI.get_notification_group_result(user, group_key, %{})

    if Enum.empty?(notifications) do
      conn
      |> put_status(:not_found)
      |> json(%{"error" => "Notification group is not found"})
    else
      grouped_types = if String.starts_with?(group_key, "ungrouped-"), do: [], else: nil

      render(conn, "grouped_index.json",
        notification_groups: [notifications],
        notification_group_counts: notification_group_counts,
        notification_group_bounds: notification_group_bounds,
        for: user,
        grouped_types: grouped_types,
        include_page_metadata: false
      )
    end
  end

  # GET /api/v2/notifications/:group_key/accounts
  def group_accounts(
        %{assigns: %{user: user}, private: %{open_api_spex: %{params: %{group_key: group_key}}}} =
          conn,
        _
      ) do
    # Mastodon paginates this endpoint in code, but the public docs say it returns accounts of all
    # notifications in the group and do not document cursor params here. Follow the documented API.
    users = MastodonAPI.get_notification_group_accounts(user, group_key)

    json(conn, AccountView.render("index.json", %{users: users, for: user}))
  end

  # GET /api/v2/notifications/unread_count
  def unread_count(
        %{private: %{open_api_spex: %{params: %{account_id: account_id} = params}}} = conn,
        _
      ) do
    case User.get_cached_by_id(account_id) do
      %{ap_id: account_ap_id} ->
        params =
          params
          |> Map.delete(:account_id)
          |> Map.put(:account_ap_id, account_ap_id)

        do_get_unread_group_count(conn, params)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Account is not found"})
    end
  end

  def unread_count(%{private: %{open_api_spex: %{params: params}}} = conn, _) do
    do_get_unread_group_count(conn, params)
  end

  # POST /api/v2/notifications/:group_key/dismiss
  def dismiss_group(
        %{assigns: %{user: user}, private: %{open_api_spex: %{params: %{group_key: group_key}}}} =
          conn,
        _
      ) do
    MastodonAPI.dismiss_notification_group(user, group_key)
    json(conn, %{})
  end

  defp do_get_notifications(%{assigns: %{user: user}} = conn, params) do
    params = normalize_notification_params(params)

    notifications = MastodonAPI.get_notifications(user, params)

    conn
    |> add_link_headers(notifications)
    |> render("index.json",
      notifications: notifications,
      for: user
    )
  end

  defp do_get_grouped_notifications(%{assigns: %{user: user}} = conn, params) do
    params = normalize_notification_params(params)

    {notification_groups, page_notifications, notification_group_counts,
     notification_group_bounds} =
      MastodonAPI.get_grouped_notification_page(user, params)

    conn
    |> add_link_headers(page_notifications)
    |> render("grouped_index.json",
      notification_groups: notification_groups,
      notification_group_counts: notification_group_counts,
      notification_group_bounds: notification_group_bounds,
      for: user,
      grouped_types: params["grouped_types"]
    )
  end

  defp do_get_unread_group_count(%{assigns: %{user: user}} = conn, params) do
    params = normalize_notification_params(params)
    json(conn, %{count: MastodonAPI.unread_notification_group_count(user, params)})
  end

  defp normalize_notification_params(params) do
    params
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("types", Map.get(params, :include_types, @default_notification_types))
  end

  # GET /api/v1/notifications/:id
  def show(%{assigns: %{user: user}, private: %{open_api_spex: %{params: %{id: id}}}} = conn, _) do
    with {:ok, notification} <- Notification.get(user, id) do
      render(conn, "show.json", notification: notification, for: user)
    else
      {:error, reason} ->
        conn
        |> put_status(:forbidden)
        |> json(%{"error" => reason})
    end
  end

  # POST /api/v1/notifications/clear
  def clear(%{assigns: %{user: user}} = conn, _params) do
    Notification.clear(user)
    json(conn, %{})
  end

  # POST /api/v1/notifications/:id/dismiss

  def dismiss(%{private: %{open_api_spex: %{params: %{id: id}}}} = conn, _) do
    do_dismiss(conn, id)
  end

  # POST /api/v1/notifications/dismiss (deprecated)
  def dismiss_via_body(
        %{private: %{open_api_spex: %{body_params: %{id: id}}}} = conn,
        _
      ) do
    do_dismiss(conn, id)
  end

  defp do_dismiss(%{assigns: %{user: user}} = conn, notification_id) do
    with {:ok, _notif} <- Notification.dismiss(user, notification_id) do
      json(conn, %{})
    else
      {:error, reason} ->
        conn
        |> put_status(:forbidden)
        |> json(%{"error" => reason})
    end
  end

  # DELETE /api/v1/notifications/destroy_multiple
  def destroy_multiple(
        %{assigns: %{user: user}, private: %{open_api_spex: %{params: %{ids: ids}}}} = conn,
        _
      ) do
    Notification.destroy_multiple(user, ids)
    json(conn, %{})
  end
end
