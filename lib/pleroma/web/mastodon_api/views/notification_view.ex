# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.NotificationView do
  use Pleroma.Web, :view

  alias Pleroma.Activity
  alias Pleroma.Chat.MessageReference
  alias Pleroma.Notification
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.UserRelationship
  alias Pleroma.Web.AdminAPI.Report
  alias Pleroma.Web.AdminAPI.ReportView
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.MastodonAPI.NotificationView
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.MediaProxy
  alias Pleroma.Web.PleromaAPI.Chat.MessageReferenceView

  defp object_id_for(%{data: %{"object" => %{"id" => id}}}) when is_binary(id), do: id

  defp object_id_for(%{data: %{"object" => id}}) when is_binary(id), do: id

  @parent_types ~w{Like Announce EmojiReact Update}

  def render("index.json", %{notifications: notifications, for: reading_user} = opts) do
    activities = Enum.map(notifications, & &1.activity)

    parent_activities =
      activities
      |> Enum.filter(fn
        %{data: %{"type" => type}} ->
          type in @parent_types
      end)
      |> Enum.map(&object_id_for/1)
      |> Activity.create_by_object_ap_id()
      |> Activity.with_preloaded_object(:left)
      |> Pleroma.Repo.all()

    relationships_opt =
      cond do
        Map.has_key?(opts, :relationships) ->
          opts[:relationships]

        is_nil(reading_user) ->
          UserRelationship.view_relationships_option(nil, [])

        true ->
          move_activities_targets =
            activities
            |> Enum.filter(&(&1.data["type"] == "Move"))
            |> Enum.map(&User.get_cached_by_ap_id(&1.data["target"]))
            |> Enum.filter(& &1)

          actors =
            activities
            |> Enum.map(fn a -> User.get_cached_by_ap_id(a.data["actor"]) end)
            |> Enum.filter(& &1)
            |> Kernel.++(move_activities_targets)

          UserRelationship.view_relationships_option(reading_user, actors, subset: :source_mutes)
      end

    opts =
      opts
      |> Map.put(:parent_activities, parent_activities)
      |> Map.put(:relationships, relationships_opt)

    safe_render_many(notifications, NotificationView, "show.json", opts)
  end

  def render("grouped_index.json", %{notifications: notifications} = opts) do
    grouped_types = Notification.normalize_grouped_types(opts[:grouped_types])

    opts
    |> Map.delete(:notifications)
    |> Map.put(
      :notification_groups,
      Notification.group_notifications(notifications, grouped_types)
    )
    |> then(&render("grouped_index.json", &1))
  end

  def render(
        "grouped_index.json",
        %{notification_groups: notification_groups, for: reading_user} = opts
      ) do
    grouped_types = Notification.normalize_grouped_types(opts[:grouped_types])
    notification_group_counts = Map.get(opts, :notification_group_counts, %{})
    notification_group_bounds = Map.get(opts, :notification_group_bounds, %{})
    include_page_metadata = Map.get(opts, :include_page_metadata, true)

    statuses =
      notification_groups
      |> Enum.map(&List.first/1)
      |> Enum.map(&render("show.json", %{notification: &1, for: reading_user}))
      |> Enum.map(& &1[:status])
      |> Enum.filter(& &1)
      |> Enum.uniq_by(& &1[:id])

    actors =
      notification_groups
      |> List.flatten()
      |> notification_actors()

    %{
      accounts: AccountView.render("index.json", %{users: actors, for: reading_user}),
      statuses: statuses,
      notification_groups:
        Enum.map(
          notification_groups,
          &render_group(
            &1,
            reading_user,
            grouped_types,
            notification_group_counts,
            notification_group_bounds,
            include_page_metadata
          )
        )
    }
  end

  def render(
        "show.json",
        %{
          notification: %Notification{activity: activity} = notification,
          for: reading_user
        } = opts
      ) do
    actor = User.get_cached_by_ap_id(activity.data["actor"])

    parent_activity_fn = fn ->
      if opts[:parent_activities] do
        Activity.Queries.find_by_object_ap_id(opts[:parent_activities], object_id_for(activity))
      else
        Activity.get_create_by_object_ap_id(object_id_for(activity))
      end
    end

    # Note: :relationships contain user mutes (needed for :muted flag in :status)
    status_render_opts = %{relationships: opts[:relationships]}
    account = AccountView.render("show.json", %{user: actor, for: reading_user})

    response = %{
      id: to_string(notification.id),
      group_key: Notification.group_key(notification),
      type: notification.type,
      created_at: CommonAPI.Utils.to_masto_date(notification.inserted_at),
      account: account,
      pleroma: %{
        is_muted: User.mutes?(reading_user, actor),
        is_seen: notification.seen
      }
    }

    case notification.type do
      type when type in ["mention", "status", "poll"] ->
        put_status(response, activity, reading_user, status_render_opts)

      type when type in ["favourite", "reblog", "update"] ->
        put_status(response, parent_activity_fn.(), reading_user, status_render_opts)

      "move" ->
        put_target(response, activity, reading_user, %{})

      "pleroma:emoji_reaction" ->
        response
        |> put_status(parent_activity_fn.(), reading_user, status_render_opts)
        |> put_emoji(activity)

      "pleroma:chat_mention" ->
        put_chat_message(response, activity, reading_user, status_render_opts)

      "pleroma:report" ->
        put_report(response, activity)

      type when type in ["follow", "follow_request"] ->
        response
    end
  end

  defp put_report(response, activity) do
    report_render = ReportView.render("show.json", Report.extract_report_info(activity))

    Map.put(response, :report, report_render)
  end

  defp render_group(
         [%Notification{} = notification | _] = notifications,
         _reading_user,
         grouped_types,
         notification_group_counts,
         notification_group_bounds,
         include_page_metadata
       ) do
    latest_notification = List.first(notifications)
    oldest_notification = List.last(notifications)
    status_activity = status_activity_for_group(notifications, grouped_types)
    group_key = Notification.group_key(notification, grouped_types)
    bounds = Map.get(notification_group_bounds, group_key, %{})

    response = %{
      group_key: group_key,
      notifications_count: Map.get(notification_group_counts, group_key, length(notifications)),
      type: notification.type,
      most_recent_notification_id:
        bounds
        |> Map.get(:page_max_id, latest_notification.id)
        |> to_string(),
      sample_account_ids:
        notifications
        |> notification_actors()
        |> Enum.map(&to_string(&1.id))
    }

    response =
      if include_page_metadata do
        Map.merge(response, %{
          page_min_id:
            bounds
            |> Map.get(:page_min_id, oldest_notification.id)
            |> to_string(),
          page_max_id:
            bounds
            |> Map.get(:page_max_id, latest_notification.id)
            |> to_string(),
          latest_page_notification_at:
            bounds
            |> Map.get(:latest_page_notification_at, latest_notification.inserted_at)
            |> CommonAPI.Utils.to_masto_date()
        })
      else
        response
      end

    if status_activity do
      Map.put(response, :status_id, to_string(status_activity.id))
    else
      response
    end
  end

  defp status_activity_for_group([%Notification{} = notification | _], grouped_types) do
    status_activity_for(notification, grouped_types)
  end

  defp status_activity_for(%Notification{type: type, activity: activity}, _grouped_types)
       when type in ["mention", "status", "poll"] do
    activity
  end

  defp status_activity_for(%Notification{type: type} = notification, grouped_types)
       when type in ["favourite", "reblog"] do
    group_key = Notification.group_key(notification, grouped_types)

    case String.split(group_key, "-", parts: 3) do
      [^type, activity_id, _bucket] ->
        case Activity.create_by_id_with_object(activity_id) do
          %Activity{} = activity -> activity
          _ -> parent_status_activity(notification.activity)
        end

      _ ->
        parent_status_activity(notification.activity)
    end
  end

  defp status_activity_for(%Notification{type: type, activity: activity}, _grouped_types)
       when type in ["update", "pleroma:emoji_reaction"] do
    parent_status_activity(activity)
  end

  defp status_activity_for(_, _grouped_types), do: nil

  defp parent_status_activity(activity) do
    Activity.get_create_by_object_ap_id(object_id_for(activity))
  end

  defp notification_actors(notifications) do
    notifications
    |> Enum.map(&User.get_cached_by_ap_id(&1.activity.data["actor"]))
    |> Enum.filter(& &1)
    |> Enum.uniq_by(& &1.id)
  end

  defp put_emoji(response, activity) do
    response
    |> Map.put(:emoji, activity.data["content"])
    |> Map.put(:emoji_url, MediaProxy.url(Pleroma.Emoji.emoji_url(activity.data)))
  end

  defp put_chat_message(response, activity, reading_user, opts) do
    object = Object.normalize(activity, fetch: false)
    author = User.get_cached_by_ap_id(object.data["actor"])
    chat = Pleroma.Chat.get(reading_user.id, author.ap_id)
    cm_ref = MessageReference.for_chat_and_object(chat, object)
    render_opts = Map.merge(opts, %{for: reading_user, chat_message_reference: cm_ref})
    chat_message_render = MessageReferenceView.render("show.json", render_opts)

    Map.put(response, :chat_message, chat_message_render)
  end

  defp put_status(response, activity, reading_user, opts) do
    status_render_opts = Map.merge(opts, %{activity: activity, for: reading_user})
    status_render = StatusView.render("show.json", status_render_opts)

    Map.put(response, :status, status_render)
  end

  defp put_target(response, activity, reading_user, opts) do
    target_user = User.get_cached_by_ap_id(activity.data["target"])
    target_render_opts = Map.merge(opts, %{user: target_user, for: reading_user})
    target_render = AccountView.render("show.json", target_render_opts)

    Map.put(response, :target, target_render)
  end
end
