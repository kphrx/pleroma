# Pleroma: A lightweight social networking server
# Copyright © Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.EctoType.Config.RateLimit do
  @moduledoc false

  use Ecto.Type

  @type t ::
          nil
          | {non_neg_integer(), non_neg_integer()}
          | [{non_neg_integer(), non_neg_integer()}]

  @impl true
  def type, do: :term

  @impl true
  def cast(value) do
    case cast_with_error(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def load(value), do: cast(value)

  @impl true
  def dump(value), do: cast(value)

  @spec cast_with_error(term()) :: {:ok, t()} | {:error, String.t()}
  def cast_with_error(nil), do: {:ok, nil}

  def cast_with_error({scale, limit}) do
    with {:ok, scale} <- parse_integer(scale, "scale"),
         {:ok, limit} <- parse_integer(limit, "limit"),
         true <- scale >= 1 and limit >= 1 do
      {:ok, {scale, limit}}
    else
      false -> {:error, "scale and limit must be >= 1"}
      {:error, reason} -> {:error, reason}
    end
  end

  def cast_with_error([{_, _} = unauth, {_, _} = auth]) do
    with {:ok, unauth} <- cast_with_error(unauth),
         {:ok, auth} <- cast_with_error(auth) do
      {:ok, [unauth, auth]}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def cast_with_error(_),
    do:
      {:error, "must be a {scale, limit} tuple, a [{scale, limit}, {scale, limit}] list, or nil"}

  defp parse_integer(value, _label) when is_integer(value), do: {:ok, value}

  defp parse_integer(value, label) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, "#{label} must be an integer"}
    end
  end

  defp parse_integer(_value, label), do: {:error, "#{label} must be an integer"}
end
