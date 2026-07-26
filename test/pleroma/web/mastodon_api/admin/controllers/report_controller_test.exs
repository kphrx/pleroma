# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.Admin.ReportControllerTest do
  use Pleroma.Web.ConnCase
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Repo
  alias Pleroma.Rule
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

  describe "GET /api/v1/admin/reports" do
    test "get reports by state", %{conn: conn} do
      [reporter, target_user] = insert_pair(:user)
      activity = insert(:note_activity, user: target_user)

      {:ok, %{id: report_id1}} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id,
          comment: "this user uses an app called Hitler Tusky",
          status_ids: [activity.id]
        })

      {:ok, %{id: report_id2}} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id,
          status_ids: [activity.id]
        })

      CommonAPI.update_report_state(report_id2, "resolved")

      assert [%{"id" => ^report_id1}] =
               conn
               |> get("/api/v1/admin/reports?unresolved=true")
               |> json_response_and_validate_schema(200)

      assert [%{"id" => ^report_id1}] =
               conn
               |> get("/api/v1/admin/reports")
               |> json_response_and_validate_schema(200)

      assert [%{"id" => ^report_id1}] =
               conn
               |> get("/api/v1/admin/reports?resolved=false")
               |> json_response_and_validate_schema(200)

      assert [%{"id" => ^report_id2}, %{"id" => ^report_id1}] =
               conn
               |> get("/api/v1/admin/reports?resolved=true&unresolved=true")
               |> json_response_and_validate_schema(200)

      assert [%{"id" => ^report_id2}] =
               conn
               |> get("/api/v1/admin/reports?resolved=true")
               |> json_response_and_validate_schema(200)
    end

    test "get reports by target account", %{conn: conn} do
      [reporter, target_user, other_target] = insert_list(3, :user)

      {:ok, %{id: report_id}} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id
        })

      {:ok, _report} =
        CommonAPI.report(reporter, %{
          account_id: other_target.id
        })

      assert [%{"id" => ^report_id}] =
               conn
               |> get("/api/v1/admin/reports?target_account_id=#{target_user.id}")
               |> json_response_and_validate_schema(200)
    end
  end

  describe "GET /api/v1/admin/reports/:id" do
    test "get report by id", %{conn: conn} do
      [reporter, target_user] = insert_pair(:user)
      activity = insert(:note_activity, user: target_user)

      {:ok, %{id: report_id}} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id,
          status_ids: [activity.id]
        })

      assert %{"id" => ^report_id} =
               conn
               |> get("/api/v1/admin/reports/#{report_id}")
               |> json_response_and_validate_schema(200)
    end

    test "returns report rules", %{conn: conn} do
      [reporter, target_user] = insert_pair(:user)
      rule = Rule.create(%{text: "Be excellent to each other"})

      {:ok, %{id: report_id}} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id,
          rule_ids: [rule.id]
        })

      assert %{
               "rules" => [
                 %{"id" => rule_id, "text" => "Be excellent to each other"}
               ]
             } =
               conn
               |> get("/api/v1/admin/reports/#{report_id}")
               |> json_response_and_validate_schema(200)

      assert rule_id == to_string(rule.id)
    end

    test "returns 404 for a missing report", %{conn: conn} do
      conn
      |> get("/api/v1/admin/reports/0")
      |> json_response_and_validate_schema(404)
    end
  end

  describe "POST /api/v1/admin/reports/:id/resolve" do
    test "resolve a report", %{conn: conn} do
      [reporter, target_user] = insert_pair(:user)
      activity = insert(:note_activity, user: target_user)

      {:ok, %{id: report_id}} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id,
          status_ids: [activity.id]
        })

      assert %{"id" => ^report_id, "action_taken" => true} =
               conn
               |> post("/api/v1/admin/reports/#{report_id}/resolve")
               |> json_response_and_validate_schema(200)
    end

    test "does not mutate a non-report activity", %{conn: conn} do
      activity = insert(:note_activity)

      conn
      |> post("/api/v1/admin/reports/#{activity.id}/resolve")
      |> json_response_and_validate_schema(404)

      refute Repo.reload!(activity).data["state"]
    end
  end

  describe "POST /api/v1/admin/reports/:id/reopen" do
    test "reopen a report", %{conn: conn} do
      [reporter, target_user] = insert_pair(:user)
      activity = insert(:note_activity, user: target_user)

      {:ok, %{id: report_id}} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id,
          status_ids: [activity.id]
        })

      CommonAPI.update_report_state(report_id, "resolved")

      assert %{"id" => ^report_id, "action_taken" => false} =
               conn
               |> post("/api/v1/admin/reports/#{report_id}/reopen")
               |> json_response_and_validate_schema(200)
    end

    test "does not mutate a non-report activity", %{conn: conn} do
      activity = insert(:note_activity)

      conn
      |> post("/api/v1/admin/reports/#{activity.id}/reopen")
      |> json_response_and_validate_schema(404)

      refute Repo.reload!(activity).data["state"]
    end
  end

  describe "POST /api/v1/admin/reports/:id/assign_to_self" do
    test "assign and unassign a report", %{admin: admin, conn: conn} do
      [reporter, target_user] = insert_pair(:user)

      {:ok, report} =
        CommonAPI.report(reporter, %{
          account_id: target_user.id
        })

      assert %{"assigned_account" => %{"id" => admin_id}} =
               conn
               |> post("/api/v1/admin/reports/#{report.id}/assign_to_self")
               |> json_response_and_validate_schema(200)

      assert admin_id == admin.id
      assert Repo.reload!(report).data["assigned_account"] == admin.id

      assert %{"assigned_account" => nil} =
               conn
               |> post("/api/v1/admin/reports/#{report.id}/unassign")
               |> json_response_and_validate_schema(200)

      refute Repo.reload!(report).data["assigned_account"]
    end

    test "does not assign a non-report activity", %{conn: conn} do
      %Activity{id: id} = activity = insert(:note_activity)

      conn
      |> post("/api/v1/admin/reports/#{id}/assign_to_self")
      |> json_response_and_validate_schema(404)

      refute Repo.reload!(activity).data["assigned_account"]
    end
  end
end
