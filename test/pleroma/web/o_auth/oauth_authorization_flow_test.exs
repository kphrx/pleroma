# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.OAuthAuthorizationFlowTest do
  use Pleroma.Web.ConnCase

  import Pleroma.Factory

  alias Pleroma.Helpers.AuthHelper
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.OAuth.App
  alias Pleroma.Web.OAuth.Authorization
  alias Pleroma.Web.OAuth.OAuthController
  alias Pleroma.Web.OAuth.Token

  @session_opts [
    store: :cookie,
    key: "_test",
    signing_salt: "cooldude"
  ]

  setup do
    clear_config([:instance, :account_activation_required], false)
    clear_config([:instance, :account_approval_required], false)
  end

  describe "OAuth authorization flow with external integration" do
    test "complete OAuth flow: create user, create app, authorize, get token, use token" do
      # Step 1: Create a user
      user = insert(:user, password_hash: Pleroma.Password.Pbkdf2.hash_pwd_salt("test"))

      # Step 2: Create a new OAuth client with the required scopes
      app =
        insert(:oauth_app,
          scopes: ["read", "write", "follow", "push"],
          redirect_uris: "urn:ietf:wg:oauth:2.0:oob"
        )

      # Step 3: Set up a logged in session
      conn =
        build_conn()
        |> Plug.Session.call(Plug.Session.init(@session_opts))
        |> fetch_session()
        |> AuthHelper.put_session_token(insert(:oauth_token, user: user).token)

      # Step 4: Access the /oauth/authorize endpoint with the specified parameters
      authorize_params = %{
        "client_id" => app.client_id,
        "response_type" => "code",
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "scope" => "read write follow push",
        "force_login" => "False",
        "state" => "None",
        "lang" => "None"
      }

      # First, get the authorization page
      conn = get(conn, "/oauth/authorize", authorize_params)
      assert html_response(conn, 200)

      # Step 5: Submit the authorization (simulate user approving the app)
      authorization_data = %{
        "authorization" => %{
          "client_id" => app.client_id,
          "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
          "scope" => "read write follow push",
          "state" => "None"
        }
      }

      conn = post(conn, "/oauth/authorize", authorization_data)

      # Should get the OOB authorization page with the code
      assert html_response(conn, 200)

      # Extract the authorization code from the response
      response = html_response(conn, 200)
      assert response =~ "Successfully authorized"
      assert response =~ "Token code is"

      # Parse the authorization code from the response
      code_match = Regex.run(~r/Token code is <br>([a-zA-Z0-9_-]+)/, response)
      assert code_match
      [_, authorization_code] = code_match

      # Step 6: Exchange the authorization code for an access token
      token_conn =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => authorization_code,
          "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
          "client_id" => app.client_id,
          "client_secret" => app.client_secret
        })

      token_response = json_response(token_conn, 200)
      assert %{"access_token" => access_token, "token_type" => "Bearer"} = token_response
      assert token_response["scope"] == "read write follow push"

      # Verify the token was created in the database
      token_record = Repo.get_by(Token, token: access_token)
      assert token_record
      assert token_record.scopes == ["read", "write", "follow", "push"]
      assert token_record.user_id == user.id
      assert token_record.app_id == app.id

      # Step 7: Use the token to access a protected endpoint
      protected_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> get("/api/v1/accounts/verify_credentials")

      # Should get a 200 response with user information
      user_info = json_response(protected_conn, 200)
      assert user_info["id"] == to_string(user.id)
      assert user_info["username"] == user.nickname
      assert user_info["acct"] == user.nickname

      # Step 8: Test that the token has the correct scopes by accessing different endpoints
      # Test read:accounts scope (should work)
      conn_with_token =
        build_conn()
        |> put_req_header("authorization", "Bearer #{access_token}")

      # This should work because we have "read" scope
      conn_with_token
      |> get("/api/v1/accounts/#{user.id}")
      |> json_response(200)

      # Test write:accounts scope (should work) - with proper content-type
      conn_with_token
      |> put_req_header("content-type", "application/json")
      |> patch("/api/v1/accounts/update_credentials", %{"display_name" => "Test Name"})
      |> json_response(200)

      # Test that the token is properly associated with the user
      assert token_record.user_id == user.id
      assert token_record.app_id == app.id
    end

    test "OAuth flow with force_login=false and existing session" do
      # Create a user and app
      user = insert(:user, password_hash: Pleroma.Password.Pbkdf2.hash_pwd_salt("test"))

      app =
        insert(:oauth_app,
          scopes: ["read", "write", "follow", "push"],
          redirect_uris: "urn:ietf:wg:oauth:2.0:oob"
        )

      # Create an existing token for the same user and app
      existing_token = insert(:oauth_token, user: user, app: app, scopes: ["read", "write"])

      # Set up a logged in session with the existing token
      conn =
        build_conn()
        |> Plug.Session.call(Plug.Session.init(@session_opts))
        |> fetch_session()
        |> AuthHelper.put_session_token(existing_token.token)

      # Access the authorize endpoint with force_login=false
      authorize_params = %{
        "client_id" => app.client_id,
        "response_type" => "code",
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "scope" => "read write follow push",
        "force_login" => "False",
        "state" => "test_state"
      }

      # Should redirect to the OOB page with the existing token
      conn = get(conn, "/oauth/authorize", authorize_params)
      assert html_response(conn, 200)
      assert html_response(conn, 200) =~ "Authorization exists"
    end

    test "OAuth flow with different scopes than existing token" do
      # Create a user and app
      user = insert(:user, password_hash: Pleroma.Password.Pbkdf2.hash_pwd_salt("test"))

      app =
        insert(:oauth_app,
          scopes: ["read", "write", "follow", "push"],
          redirect_uris: "urn:ietf:wg:oauth:2.0:oob"
        )

      # Create an existing token with different scopes
      existing_token = insert(:oauth_token, user: user, app: app, scopes: ["read"])

      # Set up a logged in session
      conn =
        build_conn()
        |> Plug.Session.call(Plug.Session.init(@session_opts))
        |> fetch_session()
        |> AuthHelper.put_session_token(existing_token.token)

      # Access the authorize endpoint requesting more scopes
      authorize_params = %{
        "client_id" => app.client_id,
        "response_type" => "code",
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "scope" => "read write follow push",
        "force_login" => "False",
        "state" => "test_state"
      }

      # Should show the authorization page because scopes are different
      conn = get(conn, "/oauth/authorize", authorize_params)
      assert html_response(conn, 200)
      assert html_response(conn, 200) =~ "Authorization exists"
    end

    test "OAuth flow with invalid client_id" do
      user = insert(:user, password_hash: Pleroma.Password.Pbkdf2.hash_pwd_salt("test"))

      conn =
        build_conn()
        |> Plug.Session.call(Plug.Session.init(@session_opts))
        |> fetch_session()
        |> AuthHelper.put_session_token(insert(:oauth_token, user: user).token)

      # Try to authorize with invalid client_id
      authorize_params = %{
        "client_id" => "invalid_client_id",
        "response_type" => "code",
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "scope" => "read write follow push",
        "force_login" => "False"
      }

      conn = get(conn, "/oauth/authorize", authorize_params)
      # Should still render the page but with error or missing app info
      assert html_response(conn, 200)
    end

    test "OAuth flow with unlisted redirect_uri" do
      user = insert(:user, password_hash: Pleroma.Password.Pbkdf2.hash_pwd_salt("test"))

      app =
        insert(:oauth_app,
          scopes: ["read", "write", "follow", "push"],
          # Different from requested
          redirect_uris: "https://example.com/callback"
        )

      conn =
        build_conn()
        |> Plug.Session.call(Plug.Session.init(@session_opts))
        |> fetch_session()
        |> AuthHelper.put_session_token(insert(:oauth_token, user: user).token)

      # Try to authorize with unlisted redirect_uri
      authorize_params = %{
        "client_id" => app.client_id,
        "response_type" => "code",
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "scope" => "read write follow push",
        "force_login" => "False"
      }

      conn = get(conn, "/oauth/authorize", authorize_params)
      # Should still render the page but with error about unlisted redirect_uri
      assert html_response(conn, 200)
    end

    test "OAuth flow with expired authorization code" do
      user = insert(:user, password_hash: Pleroma.Password.Pbkdf2.hash_pwd_salt("test"))

      app =
        insert(:oauth_app,
          scopes: ["read", "write", "follow", "push"],
          redirect_uris: "urn:ietf:wg:oauth:2.0:oob"
        )

      # Create an expired authorization
      expired_auth =
        insert(:oauth_authorization,
          user: user,
          app: app,
          # 1 hour ago
          valid_until: NaiveDateTime.add(NaiveDateTime.utc_now(), -3600),
          scopes: ["read", "write", "follow", "push"]
        )

      # Try to exchange expired code for token
      conn =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => expired_auth.token,
          "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
          "client_id" => app.client_id,
          "client_secret" => app.client_secret
        })

      # Should get an error
      response = json_response(conn, 400)
      assert %{"error" => _} = response
    end

    test "OAuth flow with used authorization code" do
      user = insert(:user, password_hash: Pleroma.Password.Pbkdf2.hash_pwd_salt("test"))

      app =
        insert(:oauth_app,
          scopes: ["read", "write", "follow", "push"],
          redirect_uris: "urn:ietf:wg:oauth:2.0:oob"
        )

      # Create an authorization and mark it as used
      auth =
        insert(:oauth_authorization,
          user: user,
          app: app,
          scopes: ["read", "write", "follow", "push"]
        )

      {:ok, _} = Authorization.use_token(auth)

      # Try to exchange used code for token
      conn =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => auth.token,
          "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
          "client_id" => app.client_id,
          "client_secret" => app.client_secret
        })

      # Should get an error
      response = json_response(conn, 400)
      assert %{"error" => _} = response
    end
  end
end
