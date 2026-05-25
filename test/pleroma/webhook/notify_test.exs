# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Webhook.NotifyTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Webhook
  alias Pleroma.Webhook.Notify

  import Pleroma.Factory

  test "triggers a webhook for a report" do
    %{id: activity_id} = activity = insert(:report_activity)

    url = "https://example.com/webhook"

    Webhook.create(%{url: url, events: [:"report.created"]})

    Tesla.Mock.mock(fn %{url: ^url, body: body} = _ ->
      report =
        body
        |> Jason.decode!()
        |> Map.get("object")

      assert %{"id" => ^activity_id} = report

      %Tesla.Env{status: 200, body: ""}
    end)

    [job] = Notify.trigger_webhooks(activity, :"report.created")

    Pleroma.Workers.WebhookWorker.perform(job)
  end

  test "triggers a webhook for an account" do
    %{id: account_id} = user = insert(:user)

    url = "https://example.com/webhook"

    Webhook.create(%{url: url, events: [:"account.created"]})

    Tesla.Mock.mock(fn %{url: ^url, body: body} = _ ->
      report =
        body
        |> Jason.decode!()
        |> Map.get("object")

      assert %{"id" => ^account_id} = report

      %Tesla.Env{status: 200, body: ""}
    end)

    [job] = Notify.trigger_webhooks(user, :"account.created")

    Pleroma.Workers.WebhookWorker.perform(job)
  end

  test "notifies have a valid signature" do
    activity = insert(:report_activity)

    {:ok, %{secret: secret} = webhook} =
      Webhook.create(%{url: "https://example.com/webhook", events: [:"report.created"]})

    Tesla.Mock.mock(fn %{url: "https://example.com/webhook", body: body, headers: headers} = _ ->
      {"X-Hub-Signature", "sha256=" <> signature} =
        Enum.find(headers, fn {key, _} -> key == "X-Hub-Signature" end)

      assert signature == :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
      %Tesla.Env{status: 200, body: ""}
    end)

    Notify.report_created(webhook, activity)
  end
end
