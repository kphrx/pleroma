# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.Admin.ReportView do
  use Pleroma.Web, :view

  alias Pleroma.HTML
  alias Pleroma.Rule
  alias Pleroma.Web.AdminAPI.Report
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.Web.MastodonAPI.Admin.AccountView
  alias Pleroma.Web.MastodonAPI.StatusView

  def render("index.json", %{reports: reports}) do
    reports
    |> Enum.map(&Report.extract_report_info/1)
    |> Enum.map(&render(__MODULE__, "show.json", &1))
  end

  def render("show.json", %{
        report: report,
        user: account,
        account: target_account,
        statuses: statuses,
        assigned_account: assigned_account
      }) do
    created_at = Utils.to_masto_date(report.data["published"])
    updated_at = Utils.to_masto_date(report.updated_at)
    action_taken = report.data["state"] != "open"

    content =
      unless is_nil(report.data["content"]) do
        HTML.filter_tags(report.data["content"])
      else
        nil
      end

    %{
      id: report.id,
      action_taken: action_taken,
      action_taken_at: if(action_taken, do: updated_at),
      category: "other",
      comment: content,
      forwarded: false,
      created_at: created_at,
      updated_at: updated_at,
      account: AccountView.render("show.json", %{user: account}),
      target_account: AccountView.render("show.json", %{user: target_account}),
      assigned_account: render_account(assigned_account),
      action_taken_by_account: nil,
      statuses:
        StatusView.render("index.json", %{
          activities: statuses,
          as: :activity
        }),
      rules: rules(report.data["rules"])
    }
  end

  defp render_account(nil), do: nil
  defp render_account(account), do: AccountView.render("show.json", %{user: account})

  defp rules(nil), do: []

  defp rules(rule_ids) do
    rule_ids
    |> Rule.get()
    |> Enum.map(&%{id: to_string(&1.id), text: &1.text})
  end
end
