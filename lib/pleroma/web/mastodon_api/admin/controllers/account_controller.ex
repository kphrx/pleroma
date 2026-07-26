# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.Admin.AccountController do
  use Pleroma.Web, :controller

  import Pleroma.Web.ControllerHelper,
    only: [
      add_link_headers: 2,
      assign_account_by_id: 2,
      json_response: 3
    ]

  alias Pleroma.Activity
  alias Pleroma.ModerationLog
  alias Pleroma.Pagination
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  @filter_params ~W(
    local external active needing_approval deactivated nickname name domain email staff origin status
  )

  plug(Pleroma.Web.ApiSpec.CastAndValidate)

  plug(
    OAuthScopesPlug,
    %{scopes: ["admin:read:accounts"]}
    when action in [:index, :index2, :show]
  )

  action_fallback(Pleroma.Web.MastodonAPI.FallbackController)

  plug(
    OAuthScopesPlug,
    %{scopes: ["admin:write:accounts"]}
    when action in [
           :delete,
           :enable,
           :account_action,
           :approve,
           :reject
         ]
  )

  plug(
    :assign_account_by_id
    when action in [
           :show,
           :delete,
           :enable,
           :account_action,
           :approve,
           :reject
         ]
  )

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.MastodonAdmin.AccountOperation

  def index(conn, params) do
    users =
      params
      |> build_criteria()
      |> User.Query.build()
      |> Pagination.fetch_paginated(params)

    conn
    |> add_link_headers(users)
    |> render("index.json", users: users)
  end

  def index2(conn, params) do
    users =
      params
      |> build_criteria_v2()
      |> User.Query.build()
      |> Pagination.fetch_paginated(params)

    conn
    |> add_link_headers(users)
    |> render("index.json", users: users)
  end

  def show(%{assigns: %{user: _admin, account: user}} = conn, _params) do
    render(conn, "show.json", user: user)
  end

  def account_action(
        %{assigns: %{user: admin, account: user}, body_params: %{type: type} = body_params} =
          conn,
        _params
      ) do
    with :ok <- validate_account_action(user, type),
         {:ok, report} <- associated_report(user, body_params),
         :ok <- resolve_report(admin, report),
         {:ok, _user} <- handle_account_action(user, admin, type) do
      json_response(conn, :no_content, "")
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, error} ->
        json_response(conn, :bad_request, %{error: error})
    end
  end

  def delete(%{assigns: %{user: admin, account: user}} = conn, _params) do
    {:ok, delete_data, _} = Builder.delete(admin, user.ap_id)
    Pipeline.common_pipeline(delete_data, local: true)

    ModerationLog.insert_log(%{
      actor: admin,
      subject: [user],
      action: "delete"
    })

    render(conn, "show.json", user: user)
  end

  def enable(%{assigns: %{user: admin, account: user}} = conn, _params) do
    {:ok, user} = User.set_activation(user, true)

    ModerationLog.insert_log(%{
      actor: admin,
      subject: [user],
      action: "activate"
    })

    render(conn, "show.json", user: user)
  end

  def approve(%{assigns: %{user: admin, account: user}} = conn, _params) do
    {:ok, user} = User.approve(user)

    ModerationLog.insert_log(%{
      actor: admin,
      subject: [user],
      action: "approve"
    })

    render(conn, "show.json", user: user)
  end

  def reject(%{assigns: %{user: admin, account: user}} = conn, _params) do
    with {:ok, _} <- User.reject(user) do
      ModerationLog.insert_log(%{
        actor: admin,
        subject: [user],
        action: "reject"
      })

      render(conn, "show.json", user: user)
    else
      {:error, error} ->
        json_response(conn, :bad_request, %{error: error})
    end
  end

  defp handle_account_action(%User{local: true} = user, admin, "disable") do
    ModerationLog.insert_log(%{
      actor: admin,
      subject: [user],
      action: "deactivate"
    })

    User.set_activation(user, false)
  end

  defp handle_account_action(%User{}, _admin, "disable") do
    {:error, "Only local accounts can be disabled"}
  end

  defp handle_account_action(user, _admin, "none") do
    {:ok, user}
  end

  defp validate_account_action(%User{local: true}, "disable"), do: :ok

  defp validate_account_action(%User{}, "disable"),
    do: {:error, "Only local accounts can be disabled"}

  defp validate_account_action(%User{}, "none"), do: :ok

  defp build_criteria(params) do
    %{}
    |> maybe_filter_local(params)
    |> maybe_filter_external(params)
    |> maybe_filter_active(params)
    |> maybe_filter_needing_approval(params)
    |> maybe_filter_deactivated(params)
    |> maybe_filter_nickname(params)
    |> maybe_filter_name(params)
    |> maybe_filter_domain(params)
    |> maybe_filter_email(params)
    |> maybe_filter_staff(params)
  end

  defp build_criteria_v2(params) do
    %{}
    |> maybe_filter_origin(params)
    |> maybe_filter_status(params)
    |> maybe_filter_staff(params)
    |> maybe_filter_nickname(params)
    |> maybe_filter_name(params)
    |> maybe_filter_domain(params)
    |> maybe_filter_email(params)
  end

  defp maybe_filter_local(criteria, %{local: true} = _params),
    do: Map.put(criteria, :local, true)

  defp maybe_filter_local(criteria, %{local: false} = _params),
    do: Map.put(criteria, :external, true)

  defp maybe_filter_external(criteria, %{remote: true} = _params),
    do: Map.put(criteria, :external, true)

  defp maybe_filter_external(criteria, %{remote: false} = _params),
    do: Map.put(criteria, :local, true)

  defp maybe_filter_origin(criteria, %{origin: "local"} = _params),
    do: Map.put(criteria, :local, true)

  defp maybe_filter_origin(criteria, %{origin: "remote"} = _params),
    do: Map.put(criteria, :external, true)

  defp maybe_filter_active(criteria, %{active: active} = _params),
    do: Map.put(criteria, :active, active)

  defp maybe_filter_needing_approval(criteria, %{pending: need_approval} = _params),
    do: Map.put(criteria, :need_approval, need_approval)

  defp maybe_filter_deactivated(criteria, %{disabled: deactivated} = _params),
    do: Map.put(criteria, :deactivated, deactivated)

  defp maybe_filter_status(criteria, %{status: "active"} = _params),
    do: Map.put(criteria, :active, true)

  defp maybe_filter_status(criteria, %{status: "inactive"} = _params),
    do: Map.put(criteria, :active, false)

  defp maybe_filter_status(criteria, %{status: "pending"} = _params),
    do: Map.put(criteria, :need_approval, true)

  defp maybe_filter_status(criteria, %{status: "disabled"} = _params),
    do: Map.put(criteria, :deactivated, true)

  defp maybe_filter_nickname(criteria, %{username: nickname} = _params),
    do: Map.put(criteria, :nickname, nickname)

  defp maybe_filter_name(criteria, %{display_name: name} = _params),
    do: Map.put(criteria, :name, name)

  defp maybe_filter_domain(criteria, %{by_domain: domain} = _params),
    do: Map.put(criteria, :domain, domain)

  defp maybe_filter_email(criteria, %{email: email} = _params),
    do: Map.put(criteria, :email, email)

  defp maybe_filter_staff(criteria, %{permissions: "staff"} = _params),
    do: Map.put(criteria, :staff, true)

  defp maybe_filter_staff(criteria, %{staff: staff} = _params),
    do: Map.put(criteria, :staff, staff)

  for filter_param <- @filter_params do
    defp unquote(:"maybe_filter_#{filter_param}")(criteria, _params), do: criteria
  end

  defp associated_report(user, %{report_id: id}) do
    case Activity.get_report(id) do
      %Activity{data: %{"object" => [target_ap_id | _]}} = report
      when target_ap_id == user.ap_id ->
        {:ok, report}

      %Activity{} ->
        {:error, "Report does not target this account"}

      nil ->
        {:error, :not_found}
    end
  end

  defp associated_report(_user, _params), do: {:ok, nil}

  defp resolve_report(admin, %Activity{id: id}) do
    with {:ok, activity} <- CommonAPI.update_report_state(id, "resolved"),
         report <- Activity.get_by_id_with_user_actor(activity.id) do
      ModerationLog.insert_log(%{
        action: "report_update",
        actor: admin,
        subject: activity,
        subject_actor: report.user_actor
      })

      :ok
    end
  end

  defp resolve_report(_admin, nil), do: :ok
end
