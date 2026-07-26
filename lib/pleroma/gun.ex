# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun do
  @callback open(charlist(), pos_integer(), map()) :: {:ok, pid()}
  @callback info(pid()) :: map()
  @callback close(pid()) :: :ok
  @callback cancel(pid(), reference() | [reference()]) :: :ok
  @callback await_up(pid, pos_integer()) :: {:ok, atom()} | {:error, atom()}
  @callback connect(pid(), map()) :: reference()
  @callback await(pid(), reference()) :: tuple()
  @callback await_tunnel_up(pid(), reference() | :undefined, timeout()) ::
              {:ok, atom()} | {:error, term()}
  @callback set_owner(pid(), pid()) :: :ok

  defp api, do: Pleroma.Config.get([Pleroma.Gun], Pleroma.Gun.API)

  def open(host, port, opts), do: api().open(host, port, opts)

  def info(pid), do: api().info(pid)

  def close(pid), do: api().close(pid)

  def cancel(pid, stream), do: api().cancel(pid, stream)

  def await_up(pid, timeout \\ 5_000), do: api().await_up(pid, timeout)

  def connect(pid, opts), do: api().connect(pid, opts)

  def await(pid, ref), do: api().await(pid, ref)

  def await_tunnel_up(pid, ref, timeout), do: api().await_tunnel_up(pid, ref, timeout)

  def set_owner(pid, owner), do: api().set_owner(pid, owner)
end
