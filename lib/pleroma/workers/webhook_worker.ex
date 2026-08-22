# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.WebhookWorker do
  alias Pleroma.Activity
  alias Pleroma.User
  alias Pleroma.Webhook
  alias Pleroma.Webhook.Notify

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
    with %Webhook{enabled: true} = webhook <- Webhook.get(webhook_id),
         %Activity{} = report <- Activity.get_by_id(report_id) do
      Notify.report_created(webhook, report)
    else
      %Webhook{enabled: false} -> {:cancel, :disabled}
      nil -> {:cancel, :not_found}
    end
  end

  def perform(%Job{
        args: %{
          "op" => "notify",
          "type" => "account.created",
          "webhook_id" => webhook_id,
          "user_id" => user_id
        }
      }) do
    with %Webhook{enabled: true} = webhook <- Webhook.get(webhook_id),
         %User{} = user <- User.get_by_id(user_id) do
      Notify.account_created(webhook, user)
    else
      %Webhook{enabled: false} -> {:cancel, :disabled}
      nil -> {:cancel, :not_found}
    end
  end

  @impl true
  def timeout(_job), do: :timer.seconds(10)
end
