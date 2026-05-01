# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorker do
  alias Pleroma.Instances
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.SignatureRetryWorker

  use Oban.Worker, queue: :federator_incoming, max_attempts: 5, unique: [period: :infinity]

  @impl true
  def perform(%Job{args: %{"op" => "incoming_ap_doc", "params" => params} = args} = job) do
    if signature_retry_job?(args) do
      perform_signature_retry(job)
    else
      perform_incoming(params)
    end
  end

  def perform(%Job{args: %{"op" => "incoming_ap_doc"} = args} = job) do
    if signature_retry_job?(args) do
      perform_signature_retry(job)
    else
      process_errors(:missing_incoming_ap_doc_params)
    end
  end

  defp perform_signature_retry(%Job{args: args} = job) do
    SignatureRetryWorker.perform(%Job{
      job
      | args: Map.put(args, "op", "incoming_failed_signature_ap_doc")
    })
  end

  defp perform_incoming(params) do
    with {:ok, res} <- Federator.perform(:incoming_ap_doc, params) do
      unless Instances.reachable?(params["actor"]) do
        domain = URI.parse(params["actor"]).host
        Oban.insert(Pleroma.Workers.ReachabilityWorker.new(%{"domain" => domain}))
      end

      {:ok, res}
    else
      e -> process_errors(e)
    end
  end

  defp signature_retry_job?(args) do
    Enum.any?(~w(method req_headers request_path query_string), &Map.has_key?(args, &1))
  end

  @impl true
  def timeout(%_{args: %{"timeout" => timeout}}), do: timeout

  def timeout(_job), do: :timer.seconds(5)

  defp process_errors({:error, {:error, _} = error}), do: process_errors(error)

  defp process_errors(errors) do
    case errors do
      # User fetch failures
      {:error, :not_found} = reason -> {:cancel, reason}
      {:error, :forbidden} = reason -> {:cancel, reason}
      # Inactive user
      {:error, {:user_active, false} = reason} -> {:cancel, reason}
      # Validator will error and return a changeset error
      # e.g., duplicate activities or if the object was deleted
      {:error, {:validate, {:error, _changeset} = reason}} -> {:cancel, reason}
      # Duplicate detection during Normalization
      {:error, :already_present} -> {:cancel, :already_present}
      # MRFs will return a reject
      {:error, {:reject, _} = reason} -> {:cancel, reason}
      # HTTP Sigs
      {:signature, false} -> {:cancel, :invalid_signature}
      {:same_actor, false} -> {:cancel, :actor_signature_mismatch}
      # Origin / URL validation failed somewhere possibly due to spoofing
      {:error, :origin_containment_failed} -> {:cancel, :origin_containment_failed}
      # Unclear if this can be reached
      {:error, {:side_effects, {:error, :no_object_actor}} = reason} -> {:cancel, reason}
      :missing_incoming_ap_doc_params -> {:cancel, :missing_incoming_ap_doc_params}
      # Catchall
      {:error, _} = e -> e
      e -> {:error, e}
    end
  end
end
