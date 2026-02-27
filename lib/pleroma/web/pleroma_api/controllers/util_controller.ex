# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.UtilController do
  use Pleroma.Web, :controller

  require Logger

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Emoji
  alias Pleroma.Healthcheck
  alias Pleroma.User
  alias Pleroma.Utils.URIEncoding
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.Auth.WrapperAuthenticator, as: Authenticator
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(Pleroma.Web.ApiSpec.CastAndValidate, [replace_params: false])

  plug(
    OAuthScopesPlug,
    %{scopes: ["write:accounts"]}
    when action in [
           :change_email,
           :change_password,
           :delete_account,
           :update_notification_settings,
           :disable_account,
           :move_account,
           :add_alias,
           :delete_alias
         ]
  )

  plug(
    OAuthScopesPlug,
    %{scopes: ["read:accounts"]}
    when action in [
           :list_aliases
         ]
  )

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.PleromaUtilOperation

  def frontend_configurations(conn, _params) do
    render(conn, "frontend_configurations.json")
  end

  def emoji(conn, _params) do
    emoji =
      Enum.reduce(Emoji.get_all(), %{}, fn {code, %Emoji{file: file, tags: tags}}, acc ->
        file = encode_emoji_url(file)
        Map.put(acc, code, %{image_url: file, tags: tags})
      end)

    json(conn, emoji)
  end

  defp encode_emoji_url(nil), do: nil
  defp encode_emoji_url("http" <> _ = url), do: URIEncoding.encode_url(url)

  defp encode_emoji_url("/" <> _ = path),
    do: URIEncoding.encode_url(path, bypass_parse: true, bypass_decode: true)

  defp encode_emoji_url(path) when is_binary(path),
    do: URIEncoding.encode_url(path, bypass_parse: true, bypass_decode: true)

  def update_notification_settings(%{assigns: %{user: user}} = conn, params) do
    with {:ok, _} <- User.update_notification_settings(user, params) do
      json(conn, %{status: "success"})
    end
  end

  def change_password(
        %{assigns: %{user: user}, private: %{open_api_spex: %{body_params: body_params}}} = conn,
        _
      ) do
    with {:ok, %User{}} <-
           Authenticator.change_password(
             user,
             body_params.password,
             body_params.new_password,
             body_params.new_password_confirmation
           ) do
      json(conn, %{status: "success"})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {_, {error, _}} = Enum.at(changeset.errors, 0)
        json(conn, %{error: "New password #{error}."})

      {:error, :password_confirmation} ->
        json(conn, %{error: "New password does not match confirmation."})

      {:error, msg} ->
        json(conn, %{error: msg})
    end
  end

  def change_email(
        %{assigns: %{user: user}, private: %{open_api_spex: %{body_params: body_params}}} = conn,
        _
      ) do
    case CommonAPI.Utils.confirm_current_password(user, body_params.password) do
      {:ok, user} ->
        with {:ok, _user} <- User.change_email(user, body_params.email) do
          json(conn, %{status: "success"})
        else
          {:error, changeset} ->
            {_, {error, _}} = Enum.at(changeset.errors, 0)
            json(conn, %{error: "Email #{error}."})

          _ ->
            json(conn, %{error: "Unable to change email."})
        end

      {:error, msg} ->
        json(conn, %{error: msg})
    end
  end

  def delete_account(
        %{
          assigns: %{user: user},
          private: %{open_api_spex: %{body_params: body_params, params: params}}
        } = conn,
        _
      ) do
    # This endpoint can accept a query param or JSON body for backwards-compatibility.
    # Submitting a JSON body is recommended, so passwords don't end up in server logs.
    password = body_params[:password] || params[:password] || ""

    case CommonAPI.Utils.confirm_current_password(user, password) do
      {:ok, user} ->
        User.delete(user)
        json(conn, %{status: "success"})

      {:error, msg} ->
        json(conn, %{error: msg})
    end
  end

  def disable_account(
        %{assigns: %{user: user}, private: %{open_api_spex: %{params: params}}} = conn,
        _
      ) do
    case CommonAPI.Utils.confirm_current_password(user, params[:password]) do
      {:ok, user} ->
        User.set_activation_async(user, false)
        json(conn, %{status: "success"})

      {:error, msg} ->
        json(conn, %{error: msg})
    end
  end

  def move_account(
        %{assigns: %{user: user}, private: %{open_api_spex: %{body_params: body_params}}} = conn,
        _
      ) do
    case CommonAPI.Utils.confirm_current_password(user, body_params.password) do
      {:ok, user} ->
        with {:ok, target_user} <- find_or_fetch_user_by_nickname(body_params.target_account),
             {:ok, _user} <- ActivityPub.move(user, target_user) do
          json(conn, %{status: "success"})
        else
          {:not_found, _} ->
            conn
            |> put_status(404)
            |> json(%{error: "Target account not found."})

          {:error, error} ->
            json(conn, %{error: error})
        end

      {:error, msg} ->
        json(conn, %{error: msg})
    end
  end

  def add_alias(
        %{assigns: %{user: user}, private: %{open_api_spex: %{body_params: body_params}}} = conn,
        _
      ) do
    with {:ok, alias_user} <- find_user_by_nickname(body_params.alias),
         {:ok, _user} <- user |> User.add_alias(alias_user) do
      json(conn, %{status: "success"})
    else
      {:not_found, _} ->
        conn
        |> put_status(404)
        |> json(%{error: "Target account does not exist."})

      {:error, error} ->
        json(conn, %{error: error})
    end
  end

  def delete_alias(
        %{assigns: %{user: user}, private: %{open_api_spex: %{body_params: body_params}}} = conn,
        _
      ) do
    with {:ok, alias_user} <- find_user_by_nickname(body_params.alias),
         {:ok, _user} <- user |> User.delete_alias(alias_user) do
      json(conn, %{status: "success"})
    else
      {:error, :no_such_alias} ->
        conn
        |> put_status(404)
        |> json(%{error: "Account has no such alias."})

      {:error, error} ->
        json(conn, %{error: error})
    end
  end

  def list_aliases(%{assigns: %{user: user}} = conn, _) do
    alias_nicks =
      user
      |> User.alias_users()
      |> Enum.map(&User.full_nickname/1)

    json(conn, %{aliases: alias_nicks})
  end

  defp find_user_by_nickname(nickname) do
    user = User.get_cached_by_nickname(nickname)

    if user == nil do
      {:error, :not_found}
    else
      {:ok, user}
    end
  end

  defp find_or_fetch_user_by_nickname(nickname) do
    user = User.get_by_nickname(nickname)

    if user != nil and user.local do
      {:ok, user}
    else
      with {:ok, user} <- User.fetch_by_nickname(nickname) do
        {:ok, user}
      else
        _ ->
          {:not_found, nil}
      end
    end
  end

  def captcha(conn, _params) do
    json(conn, Pleroma.Captcha.new())
  end

  def healthcheck(conn, _params) do
    with {:cfg, true} <- {:cfg, Config.get([:instance, :healthcheck])},
         %{healthy: true} = info <- Healthcheck.system_info() do
      json(conn, info)
    else
      %{healthy: false} = info ->
        service_unavailable(conn, info)

      {:cfg, false} ->
        service_unavailable(conn, %{"error" => "Healthcheck disabled"})

      _ ->
        service_unavailable(conn, %{})
    end
  end

  defp service_unavailable(conn, info) do
    conn
    |> put_status(:service_unavailable)
    |> json(info)
  end
end
