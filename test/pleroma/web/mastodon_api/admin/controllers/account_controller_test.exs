# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.Admin.AccountControllerTest do
  use Pleroma.Web.ConnCase
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)

    :ok
  end

  setup do
    admin = insert(:user, is_admin: true)
    token = insert(:oauth_admin_token, user: admin)

    conn =
      build_conn()
      |> assign(:user, admin)
      |> assign(:token, token)

    {:ok, %{admin: admin, token: token, conn: conn}}
  end

  describe "GET /api/v1/admin/accounts" do
    test "search by display name", %{conn: conn} do
      %{id: id} = insert(:user, name: "Display name")
      insert(:user, name: "Other name")

      assert [%{"id" => ^id}] =
               conn
               |> get("/api/v1/admin/accounts?display_name=Display")
               |> json_response_and_validate_schema(200)
    end
  end

  # Adapted from
  # https://github.com/mastodon/mastodon/blob/main/spec/requests/api/v2/admin/accounts_spec.rb
  describe "GET /api/v2/admin/accounts" do
    setup do
      remote_account = insert(:user, nickname: "remote@example.org", local: false)
      other_remote_account = insert(:user, nickname: "other@foo.bar", local: false)
      # suspended_account = insert(:user)
      # suspended_remote = insert(:user)
      disabled_account = insert(:user, is_active: false)
      pending_account = insert(:user, is_approved: false)
      admin_account = insert(:user, is_admin: true)

      {:ok,
       %{
         remote_account: remote_account,
         other_remote_account: other_remote_account,
         disabled_account: disabled_account,
         pending_account: pending_account,
         admin_account: admin_account
       }}
    end

    # test "returns the correct accounts when called with status active
    # and origin local and permissions staff", %{
    #   conn: conn,
    #   admin_account: %{id: admin_account_id}
    # } do
    #   assert [%{"id" => ^admin_account_id}] =
    #            conn
    #            |> get("/api/v2/admin/accounts?status=active&origin=local&permissions=staff")
    #            |> json_response_and_validate_schema(200)
    # end

    test "returns the correct accounts when called with by_domain value and origin remote", %{
      conn: conn,
      remote_account: %{id: remote_account_id}
    } do
      assert [%{"id" => ^remote_account_id}] =
               conn
               |> get("/api/v2/admin/accounts?by_domain=example.org&origin=remote")
               |> json_response_and_validate_schema(200)
    end

    # test "returns the correct accounts when called with status suspended", %{
    #   conn: conn,
    #   suspended_account: %{id: suspended_account_id}
    # } do
    #   assert [%{"id" => ^suspended_account_id}] =
    #            conn
    #            |> get("/api/v2/admin/accounts?status=suspended")
    #            |> json_response_and_validate_schema(200)
    # end

    test "returns the correct accounts when called with status disabled", %{
      conn: conn,
      disabled_account: %{id: disabled_account_id}
    } do
      assert [%{"id" => ^disabled_account_id}] =
               conn
               |> get("/api/v2/admin/accounts?status=disabled")
               |> json_response_and_validate_schema(200)
    end

    test "returns the correct accounts when called with status pending", %{
      conn: conn,
      pending_account: %{id: pending_account_id}
    } do
      assert [%{"id" => ^pending_account_id}] =
               conn
               |> get("/api/v2/admin/accounts?status=pending")
               |> json_response_and_validate_schema(200)
    end

    test "sets the correct pagination headers with limit param", %{
      conn: conn,
      admin_account: %{id: admin_account_id}
    } do
      response =
        conn
        |> get("/api/v2/admin/accounts?limit=1")

      next_url =
        ~r{<.+?(?<link>/api[^>]+)>; rel=\"next\"}
        |> Regex.named_captures(get_resp_header(response, "link") |> Enum.at(0))
        |> Map.get("link")

      next_url =~ "&limit=1&max_id=#{admin_account_id}"
    end
  end

  describe "GET /api/v1/admin/accounts/:id" do
    test "show admin-level information", %{conn: conn} do
      %{id: id} =
        insert(:user,
          email: "email@example.com",
          is_confirmed: false,
          is_moderator: true
        )

      assert %{
               "id" => ^id,
               "email" => "email@example.com",
               "confirmed" => false,
               "role" => "moderator"
             } =
               conn
               |> get("/api/v1/admin/accounts/#{id}")
               |> json_response_and_validate_schema(200)
    end
  end

  describe "DELETE /api/v1/admin/accounts/:id" do
    test "delete account", %{conn: conn} do
      %{id: id} = user = insert(:user)

      conn
      |> delete("/api/v1/admin/accounts/#{id}")
      |> json_response_and_validate_schema(200)

      user = Repo.reload!(user)

      assert %{is_active: false} = user
    end
  end

  describe "POST /api/v1/admin/accounts/:id/action" do
    test "disable account", %{conn: conn} do
      %{id: id} = user = insert(:user)

      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/admin/accounts/#{id}/action", %{
        "type" => "disable"
      })
      |> json_response_and_validate_schema(204)

      user = Repo.reload!(user)

      assert %{is_active: false} = user
    end

    test "perform action with assigned report", %{conn: conn} do
      [reporter, target_user] = insert_pair(:user)

      {:ok, %{id: report_id} = report} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id
        })

      %{id: id} = insert(:user)

      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/admin/accounts/#{id}/action", %{
        "type" => "none",
        "report_id" => report_id
      })
      |> json_response_and_validate_schema(204)

      report = Repo.reload!(report)

      assert %{data: %{"state" => "resolved"}} = report
    end
  end

  describe "POST /api/v1/admin/accounts/:id/enable" do
    test "enable account", %{conn: conn} do
      %{id: id} = user = insert(:user)
      User.set_activation(user, false)

      conn
      |> post("/api/v1/admin/accounts/#{id}/enable")
      |> json_response_and_validate_schema(200)

      user = Repo.reload!(user)

      assert %{is_active: true} = user
    end
  end

  describe "POST /api/v1/admin/accounts/:id/approve" do
    test "approve account", %{conn: conn} do
      %{id: id} = user = insert(:user, is_approved: false)

      conn
      |> post("/api/v1/admin/accounts/#{id}/approve")
      |> json_response_and_validate_schema(200)

      user = Repo.reload!(user)

      assert %{is_approved: true} = user
    end
  end

  describe "POST /api/v1/admin/accounts/:id/reject" do
    test "reject account", %{conn: conn} do
      %{id: id} = user = insert(:user, is_approved: false)

      conn
      |> post("/api/v1/admin/accounts/#{id}/reject")
      |> json_response_and_validate_schema(200)

      user = Repo.reload!(user)

      assert %{is_active: false} = user
    end

    test "do not allow rejecting already accepted accounts", %{conn: conn} do
      %{id: id} = user = insert(:user, is_approved: true)

      assert %{"error" => "User is approved"} ==
               conn
               |> post("/api/v1/admin/accounts/#{id}/reject")
               |> json_response_and_validate_schema(400)

      user = Repo.reload!(user)

      assert %{is_approved: true} = user
    end
  end
end
