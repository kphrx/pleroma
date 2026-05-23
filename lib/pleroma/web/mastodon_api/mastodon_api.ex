# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.MastodonAPI do
  import Ecto.Query
  import Ecto.Changeset

  alias Pleroma.Marker
  alias Pleroma.Notification
  alias Pleroma.Pagination
  alias Pleroma.Repo
  alias Pleroma.ScheduledActivity
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  @notification_group_sample_limit 8

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
    grouped_types =
      params
      |> Map.get("grouped_types", Map.get(params, :grouped_types))
      |> Notification.normalize_grouped_types()

    query = notifications_query(user, params)
    {order, cursor_filters} = group_pagination(params)

    group_rows =
      query
      |> notification_group_rows(grouped_types, grouped_limit(params), order, cursor_filters)

    group_rows = if order == :asc, do: Enum.reverse(group_rows), else: group_rows

    page_notifications = representative_notifications(query, group_rows)

    notification_groups =
      Enum.map(group_rows, &notification_group_sample(user, params, &1.group_key))

    {
      notification_groups,
      page_notifications,
      notification_group_counts(group_rows),
      notification_group_bounds(group_rows)
    }
  end

  def get_grouped_notification_groups(user, params \\ %{}) do
    {groups, _notifications, _notification_group_counts, _notification_group_bounds} =
      get_grouped_notification_page(user, params)

    groups
  end

  def get_notification_group_result(user, group_key, params \\ %{}) do
    notifications = notification_group_sample(user, params, group_key)
    metadata = notification_group_metadata(user, group_key, params)

    if Enum.empty?(notifications) or is_nil(metadata) do
      {[], %{}, %{}}
    else
      {
        notifications,
        %{group_key => metadata.notifications_count},
        %{group_key => Map.drop(metadata, [:notifications_count])}
      }
    end
  end

  def get_notification_group(user, group_key, params \\ %{})

  def get_notification_group(user, "ungrouped-" <> notification_id, _params) do
    case Notification.get(user, notification_id) do
      {:ok, notification} -> [notification]
      _ -> []
    end
  end

  def get_notification_group(user, group_key, params) do
    notification_group_sample(user, params, group_key)
  end

  def get_notification_group_accounts(user, "ungrouped-" <> notification_id) do
    with {:ok, notification} <- Notification.get(user, notification_id),
         %User{} = actor <- User.get_cached_by_ap_id(notification.activity.data["actor"]) do
      [actor]
    else
      _ -> []
    end
  end

  def get_notification_group_accounts(user, group_key) do
    user
    |> notification_group_query(group_key, %{})
    |> exclude(:preload)
    |> distinct(true)
    |> select([user_actor: user_actor], user_actor)
    |> Repo.all()
  end

  def dismiss_notification_group(user, "ungrouped-" <> notification_id) do
    Notification.destroy_multiple(user, [notification_id])
  end

  def dismiss_notification_group(%User{id: user_id}, group_key) do
    Notification
    |> where([n], n.user_id == ^user_id and n.group_key == ^group_key)
    |> Repo.delete_all()
  end

  defp group_pagination(params) do
    cond do
      min_id = Map.get(params, "min_id", Map.get(params, :min_id)) ->
        cursor_filters = [{:gt, min_id}]

        cursor_filters =
          case Map.get(params, "max_id", Map.get(params, :max_id)) do
            nil -> cursor_filters
            max_id -> [{:lt, max_id} | cursor_filters]
          end

        {:asc, cursor_filters}

      since_id = Map.get(params, "since_id", Map.get(params, :since_id)) ->
        {:desc, [{:gt, since_id}]}

      max_id = Map.get(params, "max_id", Map.get(params, :max_id)) ->
        {:desc, [{:lt, max_id}]}

      true ->
        {:desc, []}
    end
  end

  defp grouped_limit(params) do
    params
    |> Map.get("limit", Map.get(params, :limit, 40))
    |> parse_limit(40)
    |> min(80)
  end

  def unread_notification_group_count(user, params \\ %{}) do
    grouped_types =
      params
      |> Map.get("grouped_types", Map.get(params, :grouped_types))
      |> Notification.normalize_grouped_types()

    limit = unread_count_limit(params)

    user
    |> notifications_query(params)
    # The grouped API docs define unread by the notifications marker, not by Pleroma's per-row
    # seen flag used by the v1 unread count. Keep this marker-based for Mastodon clients.
    |> restrict_after_marker(notification_marker_last_read_id(user))
    |> notification_group_rows(grouped_types, limit, :desc, [])
    |> length()
  end

  defp notification_group_rows(query, grouped_types, group_limit, :desc, cursor_filters) do
    query
    |> notification_group_keyed_query(grouped_types)
    |> group_by([n], n.group_key)
    |> apply_group_cursor_filters(cursor_filters)
    |> select([n], %{
      group_key: n.group_key,
      representative_id: max(n.id),
      notifications_count: count(n.id),
      page_min_id: min(n.id),
      page_max_id: max(n.id),
      latest_page_notification_at: max(n.inserted_at)
    })
    |> order_by([n], desc: max(n.id))
    |> limit(^group_limit)
    |> Repo.all()
  end

  defp notification_group_rows(query, grouped_types, group_limit, :asc, cursor_filters) do
    query
    |> notification_group_keyed_query(grouped_types)
    |> group_by([n], n.group_key)
    |> apply_group_cursor_filters(cursor_filters)
    |> select([n], %{
      group_key: n.group_key,
      representative_id: max(n.id),
      notifications_count: count(n.id),
      page_min_id: min(n.id),
      page_max_id: max(n.id),
      latest_page_notification_at: max(n.inserted_at)
    })
    |> order_by([n], asc: max(n.id))
    |> limit(^group_limit)
    |> Repo.all()
  end

  defp apply_group_cursor_filters(query, []), do: query

  defp apply_group_cursor_filters(query, [{:gt, id} | rest]) do
    query
    |> having([n], max(n.id) > ^id)
    |> apply_group_cursor_filters(rest)
  end

  defp apply_group_cursor_filters(query, [{:lt, id} | rest]) do
    query
    |> having([n], max(n.id) < ^id)
    |> apply_group_cursor_filters(rest)
  end

  defp notification_group_keyed_query(query, grouped_types) do
    query
    |> exclude(:preload)
    |> select([n], %{
      id: n.id,
      inserted_at: n.inserted_at,
      group_key:
        fragment(
          "CASE WHEN ? IS NOT NULL AND ?::text = ANY(?) THEN ? ELSE 'ungrouped-' || ?::text END",
          n.group_key,
          n.type,
          type(^grouped_types, {:array, :string}),
          n.group_key,
          n.id
        )
    })
    |> subquery()
  end

  defp representative_notifications(_query, []), do: []

  defp representative_notifications(query, group_rows) do
    representative_ids = Enum.map(group_rows, & &1.representative_id)

    notifications_by_id =
      query
      |> where([n], n.id in ^representative_ids)
      |> Repo.all()
      |> Map.new(&{to_string(&1.id), &1})

    group_rows
    |> Enum.map(&Map.get(notifications_by_id, to_string(&1.representative_id)))
    |> Enum.filter(& &1)
  end

  defp notification_group_counts(group_rows) do
    Map.new(group_rows, &{&1.group_key, &1.notifications_count})
  end

  defp notification_group_bounds(group_rows) do
    Map.new(group_rows, fn row ->
      {row.group_key,
       %{
         page_min_id: row.page_min_id,
         page_max_id: row.page_max_id,
         latest_page_notification_at: row.latest_page_notification_at
       }}
    end)
  end

  defp notification_group_sample(user, _params, "ungrouped-" <> notification_id) do
    case Notification.get(user, notification_id) do
      {:ok, notification} -> [notification]
      _ -> []
    end
  end

  defp notification_group_sample(user, params, group_key) do
    user
    |> notification_group_query(group_key, params)
    |> order_by([n], desc: n.id)
    |> limit(^@notification_group_sample_limit)
    |> Repo.all()
  end

  defp notification_group_metadata(user, "ungrouped-" <> notification_id, _params) do
    case Notification.get(user, notification_id) do
      {:ok, notification} ->
        %{
          notifications_count: 1,
          page_min_id: notification.id,
          page_max_id: notification.id,
          latest_page_notification_at: notification.inserted_at
        }

      _ ->
        nil
    end
  end

  defp notification_group_metadata(user, group_key, params) do
    user
    |> notification_group_query(group_key, params)
    |> exclude(:preload)
    |> select([n], %{
      notifications_count: count(n.id),
      page_min_id: min(n.id),
      page_max_id: max(n.id),
      latest_page_notification_at: max(n.inserted_at)
    })
    |> Repo.one()
    |> case do
      %{notifications_count: 0} -> nil
      metadata -> metadata
    end
  end

  defp notification_group_query(user, group_key, params) do
    user
    |> notifications_query(params)
    |> where([n], n.group_key == ^group_key)
  end

  defp notification_marker_last_read_id(user) do
    Marker
    |> where([m], m.user_id == ^user.id and m.timeline == "notifications")
    |> select([m], m.last_read_id)
    |> Repo.one()
  end

  defp restrict_after_marker(query, last_read_id)
       when is_binary(last_read_id) and last_read_id != "" do
    where(query, [n], n.id > ^last_read_id)
  end

  defp restrict_after_marker(query, _last_read_id), do: query

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
