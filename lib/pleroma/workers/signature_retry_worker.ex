# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.SignatureRetryWorker do
  alias Pleroma.Instances
  alias Pleroma.Signature
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.Federator
  alias Pleroma.Web.Plugs.MappedSignatureToIdentityPlug

  require Logger

  use Oban.Worker, queue: :federator_incoming, max_attempts: 5, unique: [period: :infinity]

  @impl true
  def perform(%Job{
        args: %{
          "op" => "incoming_failed_signature_ap_doc",
          "method" => method,
          "params" => params,
          "req_headers" => req_headers,
          "request_path" => request_path,
          "query_string" => query_string
        }
      })
      when is_binary(method) and is_map(params) and is_list(req_headers) and
             is_binary(request_path) and is_binary(query_string) do
    case normalize_req_headers(req_headers) do
      {:ok, req_headers} ->
        conn_data = %Plug.Conn{
          assigns: %{valid_signature: true},
          method: method,
          params: params,
          req_headers: req_headers,
          request_path: request_path,
          query_string: query_string
        }

        signature_actor_result = signature_actor_id(conn_data)

        with actor_id = Utils.get_ap_id(params["actor"]),
             {:signature_actor, {:ok, signature_actor_id}} <-
               {:signature_actor, signature_actor_result},
             {:same_actor, true} <- {:same_actor, signature_actor_id == actor_id},
             {:ok, %User{}} <- User.get_or_fetch_by_ap_id(actor_id),
             {:ok, _public_key} <- Signature.refetch_public_key(conn_data),
             {:signature, true} <- {:signature, validate_signature(conn_data)},
             {:same_actor, true} <- {:same_actor, validate_same_actor(conn_data)},
             {:ok, res} <- Federator.perform(:incoming_ap_doc, params) do
          unless Instances.reachable?(params["actor"]) do
            domain = URI.parse(params["actor"]).host
            Oban.insert(Pleroma.Workers.ReachabilityWorker.new(%{"domain" => domain}))
          end

          {:ok, res}
        else
          e -> process_errors(e, retry_log_context(params, request_path, signature_actor_result))
        end

      e ->
        process_errors(e, retry_log_context(params, request_path, nil))
    end
  end

  def perform(%Job{args: %{"op" => "incoming_failed_signature_ap_doc"} = args}) do
    process_errors(
      :missing_signature_retry_metadata,
      retry_log_context(Map.get(args, "params"), Map.get(args, "request_path"), nil)
    )
  end

  def perform(%Job{args: args}) when is_map(args) do
    process_errors(
      :missing_signature_retry_metadata,
      retry_log_context(Map.get(args, "params"), Map.get(args, "request_path"), nil)
    )
  end

  def perform(%Job{}), do: process_errors(:missing_signature_retry_metadata)

  @impl true
  def timeout(%_{args: %{"timeout" => timeout}}), do: timeout

  def timeout(_job), do: :timer.seconds(5)

  defp normalize_req_headers(req_headers) do
    req_headers
    |> Enum.reduce_while({:ok, []}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        {:cont, {:ok, [{key, value} | acc]}}

      [key, value], {:ok, acc} when is_binary(key) and is_binary(value) ->
        {:cont, {:ok, [{key, value} | acc]}}

      _, _ ->
        {:halt, {:error, :invalid_signature_retry_metadata}}
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  defp validate_same_actor(conn_data) do
    case MappedSignatureToIdentityPlug.call(conn_data, []) do
      %Plug.Conn{assigns: %{valid_signature: true}} ->
        true

      _ ->
        false
    end
  end

  defp validate_signature(conn_data) do
    Signature.validate_signature(conn_data)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp signature_actor_id(conn_data) do
    Signature.get_actor_id(conn_data)
  rescue
    _ -> {:error, :invalid_signature}
  catch
    _, _ -> {:error, :invalid_signature}
  end

  defp process_errors(errors, context \\ %{})

  defp process_errors({:error, {:error, _} = error}, context), do: process_errors(error, context)

  defp process_errors(errors, context) do
    result =
      case errors do
        # User fetch failures
        {:error, :not_found} = reason ->
          {:cancel, reason}

        {:error, :forbidden} = reason ->
          {:cancel, reason}

        # Inactive user
        {:error, {:user_active, false} = reason} ->
          {:cancel, reason}

        # Validator will error and return a changeset error
        # e.g., duplicate activities or if the object was deleted
        {:error, {:validate, {:error, _changeset} = reason}} ->
          {:cancel, reason}

        # Duplicate detection during Normalization
        {:error, :already_present} ->
          {:cancel, :already_present}

        # MRFs will return a reject
        {:error, {:reject, _} = reason} ->
          {:cancel, reason}

        # HTTP Sigs
        {:signature_actor, {:error, _}} ->
          {:cancel, :invalid_signature}

        {:signature, false} ->
          {:cancel, :invalid_signature}

        {:same_actor, false} ->
          {:cancel, :actor_signature_mismatch}

        # Origin / URL validation failed somewhere possibly due to spoofing
        {:error, :origin_containment_failed} ->
          {:cancel, :origin_containment_failed}

        # Unclear if this can be reached
        {:error, {:side_effects, {:error, :no_object_actor}} = reason} ->
          {:cancel, reason}

        # Fail closed if the retry cannot reconstruct the original request.
        :missing_signature_retry_metadata ->
          {:cancel, :missing_signature_retry_metadata}

        {:error, :invalid_signature_retry_metadata} ->
          {:cancel, :invalid_signature_retry_metadata}

        # Catchall
        {:error, _} = e ->
          e

        e ->
          {:error, e}
      end

    log_signature_retry_rejection(result, context)
    result
  end

  defp retry_log_context(params, request_path, signature_actor_result) when is_map(params) do
    signature_actor =
      case signature_actor_result do
        {:ok, actor} when is_binary(actor) -> actor
        actor when is_binary(actor) -> actor
        _ -> nil
      end

    %{
      activity_id: params["id"],
      payload_actor: Utils.get_ap_id(params["actor"]),
      request_path: request_path,
      signature_actor: signature_actor,
      type: params["type"]
    }
  end

  defp retry_log_context(_params, request_path, signature_actor_result) do
    signature_actor =
      case signature_actor_result do
        {:ok, actor} when is_binary(actor) -> actor
        actor when is_binary(actor) -> actor
        _ -> nil
      end

    %{
      activity_id: nil,
      payload_actor: nil,
      request_path: request_path,
      signature_actor: signature_actor,
      type: nil
    }
  end

  defp log_signature_retry_rejection({:cancel, reason}, context)
       when reason in [
              :actor_signature_mismatch,
              :invalid_signature,
              :invalid_signature_retry_metadata,
              :missing_signature_retry_metadata,
              :origin_containment_failed
            ] do
    Logger.warning(
      "Failed-signature inbox retry rejected " <>
        "reason=#{inspect(reason)} " <>
        "payload_actor=#{inspect(context[:payload_actor])} " <>
        "signature_actor=#{inspect(context[:signature_actor])} " <>
        "activity_id=#{inspect(context[:activity_id])} " <>
        "type=#{inspect(context[:type])} " <>
        "request_path=#{inspect(context[:request_path])}"
    )
  end

  defp log_signature_retry_rejection(_result, _context), do: :ok
end
