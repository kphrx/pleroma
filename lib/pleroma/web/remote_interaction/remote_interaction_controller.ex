# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RemoteInteraction.RemoteInteractionController do
  use Pleroma.Web, :controller

  require Logger

  alias Pleroma.Activity
  alias Pleroma.MFA
  alias Pleroma.Object.Fetcher
  alias Pleroma.User
  alias Pleroma.Web.Auth.TOTPAuthenticator
  alias Pleroma.Web.Auth.WrapperAuthenticator
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.WebFinger

  @status_types ["Article", "Event", "Note", "Video", "Page", "Question"]

  plug(
    Pleroma.Web.ApiSpec.CastAndValidate,
    [replace_params: false]
    when action == :remote_interaction
  )

  plug(Pleroma.Web.Plugs.FederatingPlug)

  # Note: follower can submit the form (with password auth) not being signed in (having no token)
  plug(
    Pleroma.Web.Plugs.OAuthScopesPlug,
    %{fallback: :proceed_unauthenticated, scopes: ["follow", "write:follows"]}
    when action == :do_follow
  )

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.RemoteInteractionOperation

  # GET /ostatus_subscribe
  #
  def follow(%{assigns: %{user: user}} = conn, %{"acct" => acct}) do
    case status?(acct) do
      true -> follow_status(conn, user, acct)
      _ -> follow_account(conn, user, acct)
    end
  end

  defp follow_status(conn, _user, acct) do
    with {:ok, object} <- Fetcher.fetch_object_from_id(acct),
         %Activity{id: activity_id} <- Activity.get_create_by_object_ap_id(object.data["id"]) do
      redirect(conn, to: Routes.o_status_path(conn, :notice, activity_id))
    else
      error ->
        handle_follow_error(conn, error)
    end
  end

  defp follow_account(conn, user, acct) do
    with {:ok, followee} <- User.get_or_fetch(acct) do
      render(conn, follow_template(user), %{error: false, followee: followee, acct: acct})
    else
      {:error, _reason} ->
        render(conn, follow_template(user), %{error: :error})
    end
  end

  defp follow_template(%User{} = _user), do: "follow.html"
  defp follow_template(_), do: "follow_login.html"

  defp status?(acct) do
    case Fetcher.fetch_and_contain_remote_object_from_id(acct) do
      {:ok, %{"type" => type}} when type in @status_types ->
        true

      _ ->
        false
    end
  end

  # POST  /ostatus_subscribe
  #
  # adds a remote account in followers if user already is signed in.
  #
  def do_follow(%{assigns: %{user: %User{} = user}} = conn, %{"user" => %{"id" => id}}) do
    with {:fetch_user, %User{} = followee} <- {:fetch_user, User.get_cached_by_id(id)},
         {:ok, _, _, _} <- CommonAPI.follow(followee, user) do
      redirect(conn, to: "/users/#{followee.id}")
    else
      error ->
        handle_follow_error(conn, error)
    end
  end

  # POST  /ostatus_subscribe
  #
  # step 1.
  # checks login\password and displays step 2 form of MFA if need.
  #
  def do_follow(conn, %{"authorization" => %{"name" => _, "password" => _, "id" => id}}) do
    with {_, %User{} = followee} <- {:fetch_user, User.get_cached_by_id(id)},
         {_, {:ok, user}, _} <- {:auth, WrapperAuthenticator.get_user(conn), followee},
         {_, _, _, false} <- {:mfa_required, followee, user, MFA.require?(user)},
         {:ok, _, _, _} <- CommonAPI.follow(followee, user) do
      redirect(conn, to: "/users/#{followee.id}")
    else
      error ->
        handle_follow_error(conn, error)
    end
  end

  # POST  /ostatus_subscribe
  #
  # step 2
  # checks TOTP code. otherwise displays form with errors
  #
  def do_follow(conn, %{"mfa" => %{"code" => code, "token" => token, "id" => id}}) do
    with {_, %User{} = followee} <- {:fetch_user, User.get_cached_by_id(id)},
         {_, _, {:ok, %{user: user}}} <- {:mfa_token, followee, MFA.Token.validate(token)},
         {_, _, _, {:ok, _}} <-
           {:verify_mfa_code, followee, token, TOTPAuthenticator.verify(code, user)},
         {:ok, _, _, _} <- CommonAPI.follow(followee, user) do
      redirect(conn, to: "/users/#{followee.id}")
    else
      error ->
        handle_follow_error(conn, error)
    end
  end

  def do_follow(%{assigns: %{user: nil}} = conn, _) do
    Logger.debug("Insufficient permissions: follow | write:follows.")
    render(conn, "followed.html", %{error: "Insufficient permissions: follow | write:follows."})
  end

  # GET /authorize_interaction
  #
  def authorize_interaction(conn, %{"uri" => uri}) do
    conn
    |> redirect(to: Routes.remote_interaction_path(conn, :follow, %{acct: uri}))
  end

  defp handle_follow_error(conn, {:mfa_token, followee, _} = _) do
    render(conn, "follow_login.html", %{error: "Wrong username or password", followee: followee})
  end

  defp handle_follow_error(conn, {:verify_mfa_code, followee, token, _} = _) do
    render(conn, "follow_mfa.html", %{
      error: "Wrong authentication code",
      followee: followee,
      mfa_token: token
    })
  end

  defp handle_follow_error(conn, {:mfa_required, followee, user, _} = _) do
    {:ok, %{token: token}} = MFA.Token.create(user)
    render(conn, "follow_mfa.html", %{followee: followee, mfa_token: token, error: false})
  end

  defp handle_follow_error(conn, {:auth, _, followee} = _) do
    render(conn, "follow_login.html", %{error: "Wrong username or password", followee: followee})
  end

  defp handle_follow_error(conn, {:fetch_user, error} = _) do
    Logger.debug("Remote follow failed with error #{inspect(error)}")
    render(conn, "followed.html", %{error: "Could not find user"})
  end

  defp handle_follow_error(conn, {:error, "Could not follow user:" <> _} = _) do
    render(conn, "followed.html", %{error: "Error following account"})
  end

  defp handle_follow_error(conn, error) do
    Logger.debug("Remote follow failed with error #{inspect(error)}")
    render(conn, "followed.html", %{error: "Something went wrong."})
  end

  def show_subscribe_form(conn, %{"nickname" => nick}) do
    with %User{} = user <- User.get_cached_by_nickname(nick),
         avatar = User.avatar_url(user) do
      conn
      |> render("subscribe.html", %{nickname: nick, avatar: avatar, error: false})
    else
      _e ->
        render(conn, "subscribe.html", %{
          nickname: nick,
          avatar: nil,
          error:
            Pleroma.Web.Gettext.dpgettext(
              "static_pages",
              "remote follow error message - user not found",
              "Could not find user"
            )
        })
    end
  end

  def show_subscribe_form(conn, %{"status_id" => id}) do
    with %Activity{} = activity <- Activity.get_by_id(id),
         {:ok, ap_id} <- get_ap_id(activity),
         %User{} = user <- User.get_cached_by_ap_id(activity.actor),
         avatar = User.avatar_url(user) do
      conn
      |> render("status_interact.html", %{
        status_link: ap_id,
        status_id: id,
        nickname: user.nickname,
        avatar: avatar,
        error: false
      })
    else
      _e ->
        render(conn, "status_interact.html", %{
          status_id: id,
          avatar: nil,
          error:
            Pleroma.Web.Gettext.dpgettext(
              "static_pages",
              "status interact error message - status not found",
              "Could not find status"
            )
        })
    end
  end

  def remote_subscribe(conn, %{"nickname" => nick, "profile" => _}) do
    show_subscribe_form(conn, %{"nickname" => nick})
  end

  def remote_subscribe(conn, %{"status_id" => id, "profile" => _}) do
    show_subscribe_form(conn, %{"status_id" => id})
  end

  def remote_subscribe(conn, %{"user" => %{"nickname" => nick, "profile" => profile}}) do
    with {:ok, %{"subscribe_address" => template}} <- WebFinger.finger(profile),
         %User{ap_id: ap_id} <- User.get_cached_by_nickname(nick) do
      conn
      |> Phoenix.Controller.redirect(external: String.replace(template, "{uri}", ap_id))
    else
      _e ->
        render(conn, "subscribe.html", %{
          nickname: nick,
          avatar: nil,
          error:
            Pleroma.Web.Gettext.dpgettext(
              "static_pages",
              "remote follow error message - unknown error",
              "Something went wrong."
            )
        })
    end
  end

  def remote_subscribe(conn, %{"status" => %{"status_id" => id, "profile" => profile}}) do
    with {:ok, %{"subscribe_address" => template}} <- WebFinger.finger(profile),
         %Activity{} = activity <- Activity.get_by_id(id),
         {:ok, ap_id} <- get_ap_id(activity) do
      conn
      |> Phoenix.Controller.redirect(external: String.replace(template, "{uri}", ap_id))
    else
      _e ->
        render(conn, "status_interact.html", %{
          status_id: id,
          avatar: nil,
          error:
            Pleroma.Web.Gettext.dpgettext(
              "static_pages",
              "status interact error message - unknown error",
              "Something went wrong."
            )
        })
    end
  end

  def remote_interaction(
        %{private: %{open_api_spex: %{body_params: %{ap_id: ap_id, profile: profile}}}} = conn,
        _params
      ) do
    with {:ok, %{"subscribe_address" => template}} <- WebFinger.finger(profile) do
      conn
      |> json(%{url: String.replace(template, "{uri}", ap_id)})
    else
      _e -> json(conn, %{error: "Couldn't find user"})
    end
  end

  defp get_ap_id(activity) do
    object = Pleroma.Object.normalize(activity, fetch: false)

    case object do
      %{data: %{"id" => ap_id}} -> {:ok, ap_id}
      _ -> {:no_ap_id, nil}
    end
  end
end
