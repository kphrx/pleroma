# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.MastodonAdmin.ReportOperation do
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Schema
  alias Pleroma.Web.ApiSpec.MastodonAdmin.AccountOperation
  alias Pleroma.Web.ApiSpec.Schemas.ApiError
  alias Pleroma.Web.ApiSpec.Schemas.FlakeID
  alias Pleroma.Web.ApiSpec.Schemas.Status

  import Pleroma.Web.ApiSpec.Helpers

  def open_api_operation(action) do
    operation = String.to_existing_atom("#{action}_operation")
    apply(__MODULE__, operation, [])
  end

  def index_operation do
    %Operation{
      tags: ["Report management (Mastodon API)"],
      summary: "View all reports",
      operationId: "MastodonAdmin.ReportController.index",
      description:
        "View all reports. Pagination may be done with HTTP Link header in the response.",
      security: [%{"oAuth" => ["admin:read:reports"]}],
      parameters:
        [
          Operation.parameter(:resolved, :query, :boolean, "Filter for resolved reports"),
          Operation.parameter(:account_id, :query, :string, "Filter by author account id"),
          Operation.parameter(
            :target_account_id,
            :query,
            :string,
            "Filter by report target account id (not implemented)"
          )
        ] ++
          pagination_params(),
      responses: %{
        200 =>
          Operation.response("Reports", "application/json", %Schema{
            title: "ArrayOfReports",
            type: :array,
            items: report()
          }),
        401 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def show_operation do
    %Operation{
      tags: ["Report management (Mastodon API)"],
      summary: "View a single report",
      operationId: "MastodonAdmin.ReportController.show",
      description: "View information about the report with the given ID.",
      security: [%{"oAuth" => ["admin:read:reports"]}],
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the report")
      ],
      responses: %{
        200 => Operation.response("Report", "application/json", report()),
        401 => Operation.response("Error", "application/json", ApiError),
        404 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def resolve_operation do
    %Operation{
      tags: ["Report management (Mastodon API)"],
      summary: "Mark as resolved",
      operationId: "MastodonAdmin.ReportController.resolve",
      description: "Mark a report as resolved with no further action taken.",
      security: [%{"oAuth" => ["admin:write:reports"]}],
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the report")
      ],
      responses: %{
        200 => Operation.response("Report", "application/json", report()),
        400 => Operation.response("Error", "application/json", ApiError),
        401 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def reopen_operation do
    %Operation{
      tags: ["Report management (Mastodon API)"],
      summary: "Re-open report",
      operationId: "MastodonAdmin.ReportController.reopen",
      description: "Reopen a currently closed report.",
      security: [%{"oAuth" => ["admin:write:reports"]}],
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the report")
      ],
      responses: %{
        200 => Operation.response("Report", "application/json", report()),
        400 => Operation.response("Error", "application/json", ApiError),
        401 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  defp report do
    %Schema{
      title: "Admin::Report",
      type: :object,
      properties: %{
        id: FlakeID,
        action_taken: %Schema{type: :boolean},
        action_taken_at: %Schema{type: :string, format: "date-time", nullable: true},
        category: %Schema{type: :string, enum: ["spam", "violation", "other"]},
        comment: %Schema{type: :string, nullable: true},
        forwarded: %Schema{type: :boolean, nullable: true},
        created_at: %Schema{type: :string, format: "date-time"},
        updated_at: %Schema{type: :string, format: "date-time"},
        account: AccountOperation.account(),
        target_account: AccountOperation.account(),
        assigned_account: %Schema{
          type: AccountOperation.account(),
          nullable: true
        },
        action_taken_by_account: %Schema{
          type: AccountOperation.account(),
          nullable: true
        },
        statuses: %Schema{
          type: :array,
          items: Status
        },
        rules: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :integer},
              text: %Schema{type: :string}
            }
          }
        }
      }
    }
  end
end
