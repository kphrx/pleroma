# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun.API do
  @behaviour Pleroma.Gun

  alias Pleroma.Gun

  @gun_keys [
    :connect_timeout,
    :http_opts,
    :http2_opts,
    :protocols,
    :retry,
    :retry_timeout,
    :trace,
    :transport,
    :tls_opts,
    :tcp_opts,
    :socks_opts,
    :ws_opts,
    :supervise
  ]

  @impl Gun
  def open(host, port, opts \\ %{}), do: :gun.open(host, port, Map.take(opts, @gun_keys))

  @impl Gun
  defdelegate info(pid), to: :gun

  @impl Gun
  defdelegate close(pid), to: :gun

  @impl Gun
  defdelegate cancel(pid, stream), to: :gun

  @impl Gun
  defdelegate await_up(pid, timeout \\ 5_000), to: :gun

  @impl Gun
  defdelegate connect(pid, opts), to: :gun

  @impl Gun
  defdelegate await(pid, ref), to: :gun

  @impl Gun
  def await_tunnel_up(pid, stream_ref, timeout) do
    monitor_ref = Process.monitor(pid)

    result =
      receive do
        {:gun_tunnel_up, ^pid, ^stream_ref, protocol} ->
          {:ok, protocol}

        {:gun_down, ^pid, _protocol, reason, _killed_streams} ->
          {:error, {:down, reason}}

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          {:error, {:down, reason}}
      after
        timeout -> {:error, :timeout}
      end

    Process.demonitor(monitor_ref, [:flush])
    result
  end

  @impl Gun
  defdelegate set_owner(pid, owner), to: :gun
end
