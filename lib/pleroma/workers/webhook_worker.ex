# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.WebhookWorker do
  alias Pleroma.Activity

  use Oban.Worker, queue: :background

  @impl true
  def perform(%Job{
        args: %{
          "op" => "notify",
          "type" => "report.created",
          "webhook_id" => webhook_id,
          "activity_id" => report_id
        }
      }) do
    webhook = Pleroma.Webhook.get(webhook_id)
    report = Activity.get_by_id(report_id)

    Pleroma.Webhook.Notify.report_created(webhook, report)
  end

  def perform(%Job{
        args: %{
          "op" => "notify",
          "type" => "account.created",
          "webhook_id" => webhook_id,
          "user_id" => user_id
        }
      }) do
    webhook = Pleroma.Webhook.get(webhook_id)
    user = Pleroma.User.get_by_id(user_id)

    Pleroma.Webhook.Notify.account_created(webhook, user)
  end

  @impl true
  def timeout(_job), do: :timer.seconds(10)
end
