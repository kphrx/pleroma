# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.EctoType.Config.Atom do
  use Ecto.Type

  require Logger

  def type, do: :atom

  def cast(key) when is_atom(key) do
    {:ok, key}
  end

  def cast(key) when is_binary(key) do
    {:ok, Pleroma.ConfigDB.string_to_elixir_types(key)}
  end

  def cast(_), do: :error

  # A key or group naming a module that no longer exists (e.g. a removed uploader)
  # must not crash loading
  def load(key) do
    {:ok, Pleroma.ConfigDB.string_to_elixir_types(key)}
  rescue
    ArgumentError ->
      Logger.warning(
        "ConfigDB: unknown module #{key} in a setting key or group, the setting is not applied"
      )

      {:ok, :invalid_atom}
  end

  def dump(key) when is_atom(key), do: {:ok, inspect(key)}
  def dump(_), do: :error
end
