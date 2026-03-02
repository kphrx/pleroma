# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.RemoteInteractionOperation do
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Schema

  import Pleroma.Web.ApiSpec.Helpers

  def open_api_operation(action) do
    operation = String.to_existing_atom("#{action}_operation")
    apply(__MODULE__, operation, [])
  end

  def remote_interaction_operation do
    %Operation{
      tags: ["Remote interaction"],
      summary: "Remote interaction",
      operationId: "RemoteInteractionController.remote_interaction",
      requestBody: request_body("Parameters", remote_interaction_request(), required: true),
      responses: %{
        200 =>
          Operation.response("Remote interaction URL", "application/json", %Schema{type: :object})
      }
    }
  end

  defp remote_interaction_request do
    %Schema{
      title: "RemoteInteractionRequest",
      description: "POST body for remote interaction",
      type: :object,
      required: [:ap_id, :profile],
      properties: %{
        ap_id: %Schema{type: :string, description: "Profile or status ActivityPub ID"},
        profile: %Schema{type: :string, description: "Remote profile webfinger"}
      }
    }
  end

  def follow_operation do
    %Operation{
      tags: ["Remote interaction"],
      summary: "Display follow form",
      operationId: "RemoteInteractionController.follow",
      parameters: [],
      responses: %{
        200 => Operation.response("Web Page", "text/html", %Schema{type: :string}),
        302 => Operation.response("Redirect to the status page", nil, nil)
      }
    }
  end

  def do_follow_operation do
    %Operation{
      tags: ["Remote interaction"],
      summary: "Perform follow activity",
      operationId: "RemoteInteractionController.do_follow",
      parameters: [],
      responses: %{
        200 => Operation.response("Web page", "text/html", %Schema{type: :string}),
        302 => Operation.response("Redirect to the account page", nil, nil)
      }
    }
  end

  def authorize_interaction_operation do
    %Operation{
      tags: ["Remote interaction"],
      summary: "Authorize remote interaction",
      operationId: "RemoteInteractionController.authorize_interaction",
      parameters: [],
      responses: %{
        302 => Operation.response("Redirect to remote_interaction path", nil, nil)
      }
    }
  end

  def show_subscribe_form_operation do
    %Operation{
      tags: ["Remote interaction"],
      summary: "Show remote subscribe form",
      operationId: "RemoteInteractionController.show_subscribe_form",
      parameters: [],
      responses: %{200 => Operation.response("Web Page", "text/html", %Schema{type: :string})}
    }
  end

  def remote_subscribe_operation do
    %Operation{
      tags: ["Remote interaction"],
      summary: "Remote Subscribe",
      operationId: "RemoteInteractionController.remote_subscribe",
      parameters: [],
      responses: %{200 => Operation.response("Web Page", "text/html", %Schema{type: :string})}
    }
  end

  def show_subscribe_form_operation do
    %Operation{
      tags: ["Remote interaction"],
      summary: "Show remote subscribe form",
      operationId: "RemoteInteractionController.show_subscribe_form",
      parameters: [],
      responses: %{200 => Operation.response("Web Page", "text/html", %Schema{type: :string})}
    }
  end
end
