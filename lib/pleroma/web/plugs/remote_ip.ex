# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.RemoteIp do
  @moduledoc """
  This is a shim to call [`RemoteIp`](https://hex.pm/packages/remote_ip) but with runtime configuration.
  """

  alias Pleroma.Config
  alias Pleroma.Helpers.InetHelper
  import Plug.Conn

  @behaviour Plug

  def init(_), do: nil

  def call(%{remote_ip: original_remote_ip} = conn, _) do
    if Config.get([__MODULE__, :enabled]) do
      new_remote_ip = remote_ip(conn) || original_remote_ip

      conn = %{conn | remote_ip: new_remote_ip}
      assign(conn, :remote_ip_found, original_remote_ip != new_remote_ip)
    else
      conn
    end
  end

  defp remote_ip(conn) do
    opts = remote_ip_opts()

    # Do not use RemoteIp.from/2 here: upstream remote_ip always applies its
    # built-in reserved ranges. Pleroma keeps :reserved configurable, so reuse
    # only the header parsing and apply Pleroma's own block classification.
    conn.req_headers
    |> RemoteIp.Headers.take(opts[:headers])
    |> RemoteIp.Headers.parse()
    |> Enum.reverse()
    |> Enum.find(&client?(&1, opts))
  end

  defp remote_ip_opts do
    reserved = Config.get([__MODULE__, :reserved], [])

    proxies =
      Config.get([__MODULE__, :proxies], [])
      |> Enum.concat(reserved)
      |> Enum.map(&InetHelper.parse_cidr/1)

    clients =
      Config.get([__MODULE__, :clients], [])
      |> Enum.map(&InetHelper.parse_cidr/1)

    [
      headers: Config.get([__MODULE__, :headers], []),
      clients: clients,
      proxies: proxies
    ]
  end

  defp client?(ip, opts) do
    client_ip?(ip, opts[:clients]) || !proxy_ip?(ip, opts[:proxies])
  end

  defp client_ip?(ip, clients) do
    Enum.any?(clients, &InetCidr.contains?(&1, ip))
  end

  defp proxy_ip?(ip, proxies) do
    Enum.any?(proxies, &InetCidr.contains?(&1, ip))
  end
end
