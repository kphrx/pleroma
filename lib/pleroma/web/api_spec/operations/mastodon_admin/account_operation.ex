# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.MastodonAdmin.AccountOperation do
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Schema
  alias Pleroma.Web.ApiSpec.Schemas.Account
  alias Pleroma.Web.ApiSpec.Schemas.ApiError
  alias Pleroma.Web.ApiSpec.Schemas.FlakeID

  import Pleroma.Web.ApiSpec.Helpers

  def open_api_operation(action) do
    operation = String.to_existing_atom("#{action}_operation")
    apply(__MODULE__, operation, [])
  end

  def index_operation do
    %Operation{
      tags: ["User administration (Mastodon API)"],
      summary: "View accounts by criteria (v1)",
      operationId: "MastodonAdmin.AccountController.index",
      description: "View accounts matching certain criteria for filtering, up to 40 at a time.",
      security: [%{"oAuth" => ["admin:read:accounts"]}],
      parameters:
        [
          Operation.parameter(:local, :query, :boolean, "Filter for local accounts?"),
          Operation.parameter(:remote, :query, :boolean, "Filter for remote accounts?"),
          Operation.parameter(
            :active,
            :query,
            :boolean,
            "Filter for currently active accounts?"
          ),
          Operation.parameter(
            :pending,
            :query,
            :boolean,
            "Filter for currently pending accounts?"
          ),
          Operation.parameter(
            :disabled,
            :query,
            :boolean,
            "Filter for currently disabled accounts?"
          ),
          Operation.parameter(
            :silenced,
            :query,
            :boolean,
            "Filter for currently silenced accounts? (not implemented yet)"
          ),
          Operation.parameter(
            :suspended,
            :query,
            :boolean,
            "Filter for currently suspended accounts? (not implemented yet)"
          ),
          Operation.parameter(
            :sensitized,
            :query,
            :boolean,
            "Filter for accounts force-marked as sensitive? (not implemented yet)"
          ),
          Operation.parameter(:username, :query, :string, "Search for the given username"),
          Operation.parameter(
            :display_name,
            :query,
            :string,
            "Search for the given display name"
          ),
          Operation.parameter(
            :by_domain,
            :query,
            :string,
            "Filter by the given domain"
          ),
          Operation.parameter(:email, :query, :string, "Lookup a user with this email"),
          Operation.parameter(
            :ip,
            :query,
            :string,
            "Lookup users with this IP address (not implemented yet)"
          ),
          Operation.parameter(:staff, :query, :boolean, "Filter for staff accounts?")
        ] ++
          pagination_params(),
      responses: %{
        200 =>
          Operation.response("Account", "application/json", %Schema{
            title: "ArrayOfAccounts",
            type: :array,
            items: account()
          }),
        401 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def index2_operation do
    %Operation{
      tags: ["User administration (Mastodon API)"],
      summary: "View accounts by criteria (v2)",
      operationId: "MastodonAdmin.AccountController.index2",
      description: "View accounts matching certain criteria for filtering, up to 40 at a time.",
      security: [%{"oAuth" => ["admin:read:accounts"]}],
      parameters:
        [
          Operation.parameter(
            :origin,
            :query,
            %Schema{type: :string, enum: ["local", "remote"]},
            "Filter for local or remote accounts"
          ),
          Operation.parameter(
            :status,
            :query,
            %Schema{
              type: :string,
              enum: ["active", "inactive", "pending", "disabled", "silenced", "suspended"]
            },
            "Filter for active, pending, disabled, silenced or suspended accounts"
          ),
          Operation.parameter(
            :permissions,
            :query,
            :string,
            "Filter for accounts with staff permissions (users that can manage reports)."
          ),
          Operation.parameter(
            :role_ids,
            :query,
            %Schema{
              oneOf: [
                %Schema{type: :array, items: %Schema{type: :string}},
                %Schema{type: :string}
              ]
            },
            "Filter for users with these roles. (not implemented yet)"
          ),
          Operation.parameter(
            :invited_by,
            :query,
            :string,
            "Lookup users invited by the account with this ID. (not implemented yet)"
          ),
          Operation.parameter(:username, :query, :string, "Search for the given username"),
          Operation.parameter(
            :display_name,
            :query,
            :string,
            "Search for the given display name"
          ),
          Operation.parameter(
            :by_domain,
            :query,
            :string,
            "Filter by the given domain"
          ),
          Operation.parameter(:email, :query, :string, "Lookup a user with this email"),
          Operation.parameter(
            :ip,
            :query,
            :string,
            "Lookup users with this IP address (not implemented yet)"
          )
        ] ++
          pagination_params(),
      responses: %{
        200 =>
          Operation.response("Account", "application/json", %Schema{
            title: "ArrayOfAccounts",
            type: :array,
            items: account()
          }),
        401 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def show_operation do
    %Operation{
      tags: ["User administration (Mastodon API)"],
      summary: "View a specific account",
      operationId: "MastodonAdmin.AccountController.show",
      description: "View admin-level information about the given account.",
      security: [%{"oAuth" => ["admin:read:accounts"]}],
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the account")
      ],
      responses: %{
        200 => Operation.response("Account", "application/json", account()),
        401 => Operation.response("Error", "application/json", ApiError),
        404 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def account_action_operation do
    %Operation{
      tags: ["User administration (Mastodon API)"],
      summary: "Perform an action against an account",
      operationId: "MastodonAdmin.AccountController.account_action",
      description:
        "Perform an action against an account and log this action in the moderation history.",
      security: [%{"oAuth" => ["admin:write:accounts"]}],
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the account")
      ],
      requestBody:
        request_body(
          "Parameters",
          %Schema{
            type: :object,
            properties: %{
              type: %Schema{
                type: :string,
                enum: ["none", "disable", "sensitive", "silence", "suspend"]
              },
              report_id: %Schema{
                type: :string,
                nullable: true,
                description: "ID of an associated report that caused this action to be taken"
              }
            }
          },
          required: true
        ),
      responses: %{
        204 => no_content_response(),
        401 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def delete_operation do
    %Operation{
      tags: ["User administration (Mastodon API)"],
      summary: "Delete a specific account",
      operationId: "MastodonAdmin.AccountController.delete",
      description: "Delete the given account.",
      security: [%{"oAuth" => ["admin:write:accounts"]}],
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the account")
      ],
      responses: %{
        200 => Operation.response("Account", "application/json", account()),
        401 => Operation.response("Error", "application/json", ApiError),
        404 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def enable_operation do
    %Operation{
      tags: ["User administration (Mastodon API)"],
      summary: "Re-enable account",
      operationId: "MastodonAdmin.AccountController.enable",
      description: "Re-enable a local account whose login is currently disabled.",
      security: [%{"oAuth" => ["admin:write:accounts"]}],
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the account")
      ],
      responses: %{
        200 => Operation.response("Account", "application/json", account()),
        401 => Operation.response("Error", "application/json", ApiError),
        404 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def approve_operation do
    %Operation{
      tags: ["User administration (Mastodon API)"],
      summary: "Approve pending account",
      operationId: "MastodonAdmin.AccountController.approve",
      description: "Approve the given local account if it is currently pending approval.",
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the account")
      ],
      responses: %{
        200 => Operation.response("Account", "application/json", account()),
        401 => Operation.response("Error", "application/json", ApiError),
        404 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def reject_operation do
    %Operation{
      tags: ["User administration (Mastodon API)"],
      summary: "Reject pending account",
      operationId: "MastodonAdmin.AccountController.reject",
      description: "Reject the given local account if it is currently pending approval.",
      parameters: [
        Operation.parameter(:id, :path, :string, "ID of the account")
      ],
      responses: %{
        200 => Operation.response("Account", "application/json", account()),
        400 => Operation.response("Error", "application/json", ApiError),
        401 => Operation.response("Error", "application/json", ApiError),
        404 => Operation.response("Error", "application/json", ApiError)
      }
    }
  end

  def account do
    %Schema{
      title: "Admin::Account",
      description: "Admin-level information about a given account.",
      type: :object,
      properties: %{
        id: FlakeID,
        username: %Schema{type: :string},
        domain: %Schema{type: :string, nullable: true},
        created_at: %Schema{type: :string, format: "date-time"},
        email: %Schema{type: :string, format: "email", nullable: true},
        ip: %Schema{type: :string, nullable: true},
        ips: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              ip: %Schema{type: :string},
              used_at: %Schema{type: :string, format: "date-time"}
            }
          }
        },
        locale: %Schema{type: :string, nullable: true},
        invite_request: %Schema{type: :string, nullable: true},
        role: %Schema{type: :string, nullable: true},
        confirmed: %Schema{type: :boolean},
        approved: %Schema{type: :boolean},
        disabled: %Schema{type: :boolean},
        silenced: %Schema{type: :boolean, nullable: true},
        suspended: %Schema{type: :boolean, nullable: true},
        account: Account,
        created_by_application_id: %Schema{type: :string, nullable: true},
        invited_by_account_id: %Schema{type: :string, nullable: true}
      }
    }
  end
end
