# Pleroma: A lightweight social networking server
# Copyright © 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.PleromaFollowRequestOperation do
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Schema
  alias Pleroma.Web.ApiSpec.Schemas.Account

  def open_api_operation(action) do
    operation = String.to_existing_atom("#{action}_operation")
    apply(__MODULE__, operation, [])
  end

  def outgoing_operation do
    %Operation{
      tags: ["Follow requests"],
      summary: "Retrieve outgoing follow requests",
      security: [%{"oAuth" => ["read:follows", "follow"]}],
      operationId: "PleromaFollowRequestController.outgoing",
      parameters: pagination_params(),
      responses: %{
        200 =>
          Operation.response("Array of Account", "application/json", %Schema{
            type: :array,
            items: Account,
            example: [Account.schema().example]
          })
      }
    }
  end

  defp pagination_params do
    [
      Operation.parameter(:max_id, :query, :string, "Return items older than this ID"),
      Operation.parameter(
        :since_id,
        :query,
        :string,
        "Return the oldest items newer than this ID"
      ),
      Operation.parameter(
        :limit,
        :query,
        %Schema{type: :integer, default: 20},
        "Maximum number of items to return. Will be ignored if it's more than 40"
      )
    ]
  end
end
