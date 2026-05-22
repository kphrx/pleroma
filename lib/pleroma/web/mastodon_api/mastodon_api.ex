# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.MastodonAPI do
  import Ecto.Query
  import Ecto.Changeset

  alias Pleroma.Notification
  alias Pleroma.Pagination
  alias Pleroma.Repo
  alias Pleroma.ScheduledActivity
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  @spec follow(User.t(), User.t(), map) :: {:ok, User.t()} | {:error, String.t()}
  def follow(follower, followed, params \\ %{}) do
    result =
      if not User.following?(follower, followed) do
        CommonAPI.follow(followed, follower)
      else
        {:ok, followed, follower, nil}
      end

    with {:ok, _followed, follower, _} <- result do
      options = cast_params(params)
      set_reblogs_visibility(options[:reblogs], result)
      set_subscription(options[:notify], result)
      {:ok, follower}
    end
  end

  defp set_reblogs_visibility(false, {:ok, followed, follower, _}) do
    CommonAPI.hide_reblogs(followed, follower)
  end

  defp set_reblogs_visibility(_, {:ok, followed, follower, _}) do
    CommonAPI.show_reblogs(followed, follower)
  end

  defp set_subscription(true, {:ok, followed, follower, _}) do
    User.subscribe(follower, followed)
  end

  defp set_subscription(false, {:ok, followed, follower, _}) do
    User.unsubscribe(follower, followed)
  end

  defp set_subscription(_, _), do: {:ok, nil}

  @spec get_followers(User.t(), map()) :: list(User.t())
  def get_followers(user, params \\ %{}) do
    user
    |> User.get_followers_query()
    |> Pagination.fetch_paginated(params)
  end

  def get_friends(user, params \\ %{}) do
    user
    |> User.get_friends_query()
    |> Pagination.fetch_paginated(params)
  end

  def get_notifications(user, params \\ %{}) do
    user
    |> notifications_query(params)
    |> Pagination.fetch_paginated(params)
  end

  def get_grouped_notification_page(user, params \\ %{}) do
    grouped_types = Map.get(params, "grouped_types", Map.get(params, :grouped_types))
    {query, order} = group_pagination_query(notifications_query(user, params), params)

    notifications =
      query
      |> order_by([n], [{^order, n.id}])
      |> Repo.all()

    notification_group_counts =
      Enum.frequencies_by(notifications, &Notification.group_key(&1, grouped_types))

    page_notifications =
      notifications
      |> take_grouped_page_notifications(grouped_types, grouped_limit(params))

    page_notifications =
      if order == :asc, do: Enum.reverse(page_notifications), else: page_notifications

    {
      Notification.group_notifications(page_notifications, grouped_types),
      page_notifications,
      notification_group_counts
    }
  end

  def get_grouped_notification_groups(user, params \\ %{}) do
    {groups, _notifications, _notification_group_counts} =
      get_grouped_notification_page(user, params)

    groups
  end

  def get_notification_group(user, group_key, params \\ %{})

  def get_notification_group(user, "ungrouped-" <> notification_id, _params) do
    case Notification.get(user, notification_id) do
      {:ok, notification} -> [notification]
      _ -> []
    end
  end

  def get_notification_group(user, group_key, params) do
    grouped_types = Map.get(params, "grouped_types", Map.get(params, :grouped_types))

    user
    |> notifications_query(params)
    |> order_by([n], desc: n.id)
    |> Repo.all()
    |> Enum.filter(&(Notification.group_key(&1, grouped_types) == group_key))
  end

  defp group_pagination_query(query, params) do
    cond do
      min_id = Map.get(params, "min_id", Map.get(params, :min_id)) ->
        query = where(query, [n], n.id > ^min_id)

        query =
          case Map.get(params, "max_id", Map.get(params, :max_id)) do
            nil -> query
            max_id -> where(query, [n], n.id < ^max_id)
          end

        {query, :asc}

      since_id = Map.get(params, "since_id", Map.get(params, :since_id)) ->
        {where(query, [n], n.id > ^since_id), :desc}

      max_id = Map.get(params, "max_id", Map.get(params, :max_id)) ->
        {where(query, [n], n.id < ^max_id), :desc}

      true ->
        {query, :desc}
    end
  end

  defp grouped_limit(params) do
    params
    |> Map.get("limit", Map.get(params, :limit, 40))
    |> parse_limit(40)
    |> min(80)
  end

  defp take_grouped_page_notifications(notifications, grouped_types, group_limit) do
    {notifications, _group_keys} =
      Enum.reduce_while(notifications, {[], MapSet.new()}, fn notification,
                                                              {notifications, group_keys} ->
        group_key = Notification.group_key(notification, grouped_types)

        cond do
          MapSet.member?(group_keys, group_key) ->
            {:cont, {[notification | notifications], group_keys}}

          MapSet.size(group_keys) < group_limit ->
            {:cont, {[notification | notifications], MapSet.put(group_keys, group_key)}}

          true ->
            {:halt, {notifications, group_keys}}
        end
      end)

    Enum.reverse(notifications)
  end

  def unread_notification_group_count(user, params \\ %{}) do
    grouped_types = Map.get(params, "grouped_types", Map.get(params, :grouped_types))
    limit = unread_count_limit(params)

    user
    |> notifications_query(params)
    |> where([n], n.seen == false)
    |> order_by([n], desc: n.id)
    |> limit(^limit)
    |> Repo.all()
    |> Notification.group_notifications(grouped_types)
    |> length()
  end

  defp notifications_query(user, params) do
    options = notification_options(user, params)

    user
    |> Notification.for_user_query(options)
    |> restrict(:types, options)
    |> restrict(:exclude_types, options)
    |> restrict(:account_ap_id, options)
  end

  defp notification_options(user, params) do
    options =
      params
      |> cast_params()
      |> Map.update(:include_types, [], fn include_types -> include_types end)

    if ("pleroma:report" not in options.include_types and
          User.privileged?(user, :reports_manage_reports)) or
         User.privileged?(user, :reports_manage_reports) do
      options
    else
      options
      |> Map.update(:exclude_types, ["pleroma:report"], fn current_exclude_types ->
        current_exclude_types ++ ["pleroma:report"]
      end)
    end
  end

  defp unread_count_limit(params) do
    params
    |> Map.get("limit", Map.get(params, :limit, 100))
    |> parse_limit(100)
    |> min(1000)
  end

  defp parse_limit(limit, _default) when is_integer(limit) and limit > 0, do: limit

  defp parse_limit(limit, default) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, _} when limit > 0 -> limit
      _ -> default
    end
  end

  defp parse_limit(_, default), do: default

  def get_scheduled_activities(user, params \\ %{}) do
    user
    |> ScheduledActivity.for_user_query()
    |> Pagination.fetch_paginated(params)
  end

  defp cast_params(params) do
    param_types = %{
      exclude_types: {:array, :string},
      types: {:array, :string},
      exclude_visibilities: {:array, :string},
      grouped_types: {:array, :string},
      limit: :integer,
      reblogs: :boolean,
      with_muted: :boolean,
      account_ap_id: :string,
      notify: :boolean
    }

    changeset = cast({%{}, param_types}, params, Map.keys(param_types))
    changeset.changes
  end

  defp restrict(query, :types, %{types: mastodon_types = [_ | _]}) do
    where(query, [n], n.type in ^mastodon_types)
  end

  defp restrict(query, :exclude_types, %{exclude_types: mastodon_types = [_ | _]}) do
    where(query, [n], n.type not in ^mastodon_types)
  end

  defp restrict(query, :account_ap_id, %{account_ap_id: account_ap_id}) do
    where(query, [n, a], a.actor == ^account_ap_id)
  end

  defp restrict(query, _, _), do: query
end
