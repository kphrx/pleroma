# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.UserValidator do
  @moduledoc """
  Checks that a remote actor document only points at its own host.

  We deliver to the inbox and shared inbox, use the collections for
  addressing and visibility checks, and map signature key ids back to
  the actor. If an actor could point any of these at another host, it
  could redirect our signed deliveries or claim another actor's
  collections. Optional fields are only checked when present; null and
  empty strings count as missing.

  Based on Akkoma's UserValidator.
  """

  @behaviour Pleroma.Web.ActivityPub.ObjectValidator.Validating

  alias Pleroma.Object.Containment

  @collections ["inbox", "followers", "following", "featured"]

  @impl true
  def validate(%{"id" => id} = data, meta) when is_binary(id) do
    fields =
      Enum.map(@collections, &{&1, data[&1]}) ++
        [
          {"sharedInbox", get_in_map(data, ["endpoints", "sharedInbox"])},
          {"publicKey", get_in_map(data, ["publicKey", "id"])}
        ]

    case Enum.find(fields, fn {_, value} -> not same_origin?(id, value) end) do
      nil -> {:ok, data, meta}
      {field, _} -> {:error, "#{field} is not on the same host as the actor"}
    end
  end

  def validate(_data, _meta), do: {:error, "Actor has no id"}

  defp same_origin?(_id, value) when value in [nil, ""], do: true
  defp same_origin?(id, %{"id" => value}), do: same_origin?(id, value)
  defp same_origin?(id, value), do: Containment.same_origin(id, value) == :ok

  defp get_in_map(data, [key | rest]) do
    case data do
      %{^key => value} when rest == [] -> value
      %{^key => value} -> get_in_map(value, rest)
      _ -> nil
    end
  end
end
