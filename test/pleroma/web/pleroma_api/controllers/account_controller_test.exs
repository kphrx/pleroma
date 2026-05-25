# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.AccountControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Config
  alias Pleroma.Tests.ObanHelpers
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory
  import Swoosh.TestAssertions

  describe "POST /api/v1/pleroma/accounts/confirmation_resend" do
    setup do
      {:ok, user} =
        insert(:user)
        |> User.confirmation_changeset(set_confirmation: false)
        |> User.update_and_set_cache()

      refute user.is_confirmed

      [user: user]
    end

    setup do: clear_config([:instance, :account_activation_required], true)

    test "resend account confirmation email", %{conn: conn, user: user} do
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/pleroma/accounts/confirmation_resend?email=#{user.email}")
      |> json_response_and_validate_schema(:no_content)

      ObanHelpers.perform_all()

      email = Pleroma.Emails.UserEmail.account_confirmation_email(user)
      notify_email = Config.get([:instance, :notify_email])
      instance_name = Config.get([:instance, :name])

      assert_email_sent(
        from: {instance_name, notify_email},
        to: {user.name, user.email},
        html_body: email.html_body
      )
    end

    test "resend account confirmation email (with nickname)", %{conn: conn, user: user} do
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/pleroma/accounts/confirmation_resend?nickname=#{user.nickname}")
      |> json_response_and_validate_schema(:no_content)

      ObanHelpers.perform_all()

      email = Pleroma.Emails.UserEmail.account_confirmation_email(user)
      notify_email = Config.get([:instance, :notify_email])
      instance_name = Config.get([:instance, :name])

      assert_email_sent(
        from: {instance_name, notify_email},
        to: {user.name, user.email},
        html_body: email.html_body
      )
    end
  end

  describe "getting favorites timeline of specified user" do
    setup do
      [current_user, user] = insert_pair(:user, hide_favorites: false)
      %{user: current_user, conn: conn} = oauth_access(["read:favourites"], user: current_user)
      [current_user: current_user, user: user, conn: conn]
    end

    test "returns list of statuses favorited by specified user", %{
      conn: conn,
      user: user
    } do
      [activity | _] = insert_pair(:note_activity)
      CommonAPI.favorite(activity.id, user)

      response =
        conn
        |> get("/api/v1/pleroma/accounts/#{user.id}/favourites")
        |> json_response_and_validate_schema(:ok)

      [like] = response

      assert length(response) == 1
      assert like["id"] == activity.id
    end

    test "returns favorites for specified user_id when requester is not logged in", %{
      user: user
    } do
      activity = insert(:note_activity)
      CommonAPI.favorite(activity.id, user)

      response =
        build_conn()
        |> get("/api/v1/pleroma/accounts/#{user.id}/favourites")
        |> json_response_and_validate_schema(200)

      assert length(response) == 1
    end

    test "orders statuses by favorite date", %{
      conn: conn,
      user: user
    } do
      other_user = insert(:user)

      {:ok, first_post} = CommonAPI.post(other_user, %{status: "first post"})
      {:ok, second_post} = CommonAPI.post(other_user, %{status: "second post"})
      {:ok, third_post} = CommonAPI.post(other_user, %{status: "third post"})

      {:ok, _} = CommonAPI.favorite(third_post.id, user)
      {:ok, _} = CommonAPI.favorite(first_post.id, user)
      {:ok, _} = CommonAPI.favorite(second_post.id, user)

      response =
        conn
        |> get("/api/v1/pleroma/accounts/#{user.id}/favourites")
        |> json_response_and_validate_schema(:ok)

      assert Enum.map(response, & &1["id"]) == [second_post.id, first_post.id, third_post.id]
    end

    test "returns favorited DM only when user is logged in and he is one of recipients", %{
      current_user: current_user,
      user: user
    } do
      {:ok, direct} =
        CommonAPI.post(current_user, %{
          status: "Hi @#{user.nickname}!",
          visibility: "direct"
        })

      CommonAPI.favorite(direct.id, user)

      for u <- [user, current_user] do
        response =
          build_conn()
          |> assign(:user, u)
          |> assign(:token, insert(:oauth_token, user: u, scopes: ["read:favourites"]))
          |> get("/api/v1/pleroma/accounts/#{user.id}/favourites")
          |> json_response_and_validate_schema(:ok)

        assert length(response) == 1
      end

      response =
        build_conn()
        |> get("/api/v1/pleroma/accounts/#{user.id}/favourites")
        |> json_response_and_validate_schema(200)

      assert length(response) == 0
    end

    test "does not return others' favorited DM when user is not one of recipients", %{
      conn: conn,
      user: user
    } do
      user_two = insert(:user)

      {:ok, direct} =
        CommonAPI.post(user_two, %{
          status: "Hi @#{user.nickname}!",
          visibility: "direct"
        })

      CommonAPI.favorite(direct.id, user)

      response =
        conn
        |> get("/api/v1/pleroma/accounts/#{user.id}/favourites")
        |> json_response_and_validate_schema(:ok)

      assert Enum.empty?(response)
    end

    test "paginates favorites using since_id and max_id", %{
      conn: conn,
      user: user
    } do
      activities = insert_list(10, :note_activity)

      favorite_pairs =
        Enum.map(activities, fn activity ->
          {:ok, favorite} = CommonAPI.favorite(activity.id, user)
          {favorite, activity}
        end)
        |> Enum.sort_by(fn {favorite, _activity} -> FlakeId.from_string(favorite.id) end)

      {third_favorite, _} = Enum.at(favorite_pairs, 2)
      {seventh_favorite, _} = Enum.at(favorite_pairs, 6)

      expected_ids =
        favorite_pairs
        |> Enum.slice(3, 3)
        |> Enum.reverse()
        |> Enum.map(fn {_favorite, activity} -> activity.id end)

      response =
        conn
        |> get(
          "/api/v1/pleroma/accounts/#{user.id}/favourites?since_id=#{third_favorite.id}&max_id=#{seventh_favorite.id}"
        )
        |> json_response_and_validate_schema(:ok)

      assert Enum.map(response, & &1["id"]) == expected_ids
    end

    test "paginates favorites using min_id and limit", %{
      conn: conn,
      user: user
    } do
      activities = insert_list(10, :note_activity)

      favorite_pairs =
        Enum.map(activities, fn activity ->
          {:ok, favorite} = CommonAPI.favorite(activity.id, user)
          {favorite, activity}
        end)
        |> Enum.sort_by(fn {favorite, _activity} -> FlakeId.from_string(favorite.id) end)

      {third_favorite, _} = Enum.at(favorite_pairs, 2)
      {fourth_favorite, _} = Enum.at(favorite_pairs, 3)
      {fifth_favorite, _} = Enum.at(favorite_pairs, 4)

      expected_ids =
        favorite_pairs
        |> Enum.slice(3, 2)
        |> Enum.reverse()
        |> Enum.map(fn {_favorite, activity} -> activity.id end)

      conn =
        get(
          conn,
          "/api/v1/pleroma/accounts/#{user.id}/favourites?min_id=#{third_favorite.id}&limit=2"
        )

      response = json_response_and_validate_schema(conn, :ok)

      assert Enum.map(response, & &1["id"]) == expected_ids
      assert [link_header] = get_resp_header(conn, "link")
      assert link_header =~ "max_id=#{fourth_favorite.id}"
      assert link_header =~ "min_id=#{fifth_favorite.id}"
    end

    test "limits favorites using limit parameter", %{
      conn: conn,
      user: user
    } do
      7
      |> insert_list(:note_activity)
      |> Enum.each(fn activity ->
        CommonAPI.favorite(activity.id, user)
      end)

      response =
        conn
        |> get("/api/v1/pleroma/accounts/#{user.id}/favourites?limit=3")
        |> json_response_and_validate_schema(:ok)

      assert length(response) == 3
    end

    test "returns empty response when user does not have any favorited statuses", %{
      conn: conn,
      user: user
    } do
      response =
        conn
        |> get("/api/v1/pleroma/accounts/#{user.id}/favourites")
        |> json_response_and_validate_schema(:ok)

      assert Enum.empty?(response)
    end

    test "returns 404 error when specified user is not exist", %{conn: conn} do
      conn = get(conn, "/api/v1/pleroma/accounts/test/favourites")

      assert json_response_and_validate_schema(conn, 404) == %{"error" => "Record not found"}
    end

    test "returns 403 error when user has hidden own favorites", %{conn: conn} do
      user = insert(:user, hide_favorites: true)
      activity = insert(:note_activity)
      CommonAPI.favorite(activity.id, user)

      conn = get(conn, "/api/v1/pleroma/accounts/#{user.id}/favourites")

      assert json_response_and_validate_schema(conn, 403) == %{"error" => "Can't get favorites"}
    end

    test "hides favorites for new users by default", %{conn: conn} do
      user = insert(:user)
      activity = insert(:note_activity)
      CommonAPI.favorite(activity.id, user)

      assert user.hide_favorites
      conn = get(conn, "/api/v1/pleroma/accounts/#{user.id}/favourites")

      assert json_response_and_validate_schema(conn, 403) == %{"error" => "Can't get favorites"}
    end
  end

  describe "subscribing / unsubscribing" do
    test "subscribing / unsubscribing to a user" do
      %{user: user, conn: conn} = oauth_access(["follow"])
      subscription_target = insert(:user)

      ret_conn =
        conn
        |> assign(:user, user)
        |> post("/api/v1/pleroma/accounts/#{subscription_target.id}/subscribe")

      assert %{"id" => _id, "subscribing" => true} =
               json_response_and_validate_schema(ret_conn, 200)

      conn = post(conn, "/api/v1/pleroma/accounts/#{subscription_target.id}/unsubscribe")

      assert %{"id" => _id, "subscribing" => false} = json_response_and_validate_schema(conn, 200)
    end
  end

  describe "subscribing" do
    test "returns 404 when subscription_target not found" do
      %{conn: conn} = oauth_access(["write:follows"])

      conn = post(conn, "/api/v1/pleroma/accounts/target_id/subscribe")

      assert %{"error" => "Record not found"} = json_response_and_validate_schema(conn, 404)
    end
  end

  describe "unsubscribing" do
    test "returns 404 when subscription_target not found" do
      %{conn: conn} = oauth_access(["follow"])

      conn = post(conn, "/api/v1/pleroma/accounts/target_id/unsubscribe")

      assert %{"error" => "Record not found"} = json_response_and_validate_schema(conn, 404)
    end
  end

  describe "birthday reminders" do
    test "returns a list of friends having birthday on specified day" do
      %{user: user, conn: conn} = oauth_access(["read:accounts"])

      %{id: id1} =
        user1 =
        insert(:user, %{
          birthday: "2001-02-12",
          show_birthday: true
        })

      user2 =
        insert(:user, %{
          birthday: "2001-02-14",
          show_birthday: true
        })

      user3 = insert(:user)

      CommonAPI.follow(user1, user)
      CommonAPI.follow(user2, user)
      CommonAPI.follow(user3, user)

      [%{"id" => ^id1}] =
        conn
        |> get("/api/v1/pleroma/birthdays?day=12&month=2")
        |> json_response_and_validate_schema(:ok)
    end

    test "the list doesn't list friends with hidden birth date" do
      %{user: user, conn: conn} = oauth_access(["read:accounts"])

      user1 =
        insert(:user, %{
          birthday: "2001-02-12",
          show_birthday: false
        })

      %{id: id2} =
        user2 =
        insert(:user, %{
          birthday: "2001-02-12",
          show_birthday: true
        })

      CommonAPI.follow(user1, user)
      CommonAPI.follow(user2, user)

      [%{"id" => ^id2}] =
        conn
        |> get("/api/v1/pleroma/birthdays?day=12&month=2")
        |> json_response_and_validate_schema(:ok)
    end
  end
end
