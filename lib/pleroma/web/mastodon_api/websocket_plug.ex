# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.WebsocketPlug do
  @moduledoc """
  A Phoenix 1.8 compatible WebSocket transport for Mastodon streaming.

  It mirrors Phoenix.Transports.WebSocket, but echoes a successfully authenticated
  Mastodon-style Sec-WebSocket-Protocol token so browser clients accept the handshake.
  """

  @behaviour Plug

  import Plug.Conn

  alias Phoenix.Socket.Transport
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.MastodonAPI.WebsocketHandler

  @connect_info_opts [:check_csrf]

  @impl Plug
  def init(opts) do
    path = String.split(Keyword.fetch!(opts, :path), "/", trim: true)
    websocket = Keyword.fetch!(opts, :websocket)
    config = Transport.load_config(websocket, Phoenix.Transports.WebSocket)

    {path, config}
  end

  @impl Plug
  def call(%{method: "GET", path_info: path} = conn, {path, opts}) do
    conn
    |> fetch_query_params()
    |> Transport.code_reload(Endpoint, opts)
    |> Transport.transport_log(opts[:transport_log])
    |> Transport.check_origin(WebsocketHandler, Endpoint, opts)
    |> connect(opts)
  end

  def call(%{path_info: path} = conn, {path, _opts}) do
    conn
    |> send_resp(400, "")
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp connect(%{halted: true} = conn, _opts), do: conn

  defp connect(%{params: params} = conn, opts) do
    keys = Keyword.get(opts, :connect_info, [])

    connect_info =
      Transport.connect_info(conn, Endpoint, keys, Keyword.take(opts, @connect_info_opts))

    config = %{
      endpoint: Endpoint,
      transport: :websocket,
      options: opts,
      params: params,
      connect_info: connect_info
    }

    case WebsocketHandler.connect(config) do
      {:ok, arg} ->
        try do
          conn
          |> echo_sec_websocket_protocol()
          |> WebSockAdapter.upgrade(WebsocketHandler, arg, opts)
          |> halt()
        rescue
          e in WebSockAdapter.UpgradeError ->
            conn
            |> send_resp(400, e.message)
            |> halt()
        end

      :error ->
        conn
        |> send_resp(403, "")
        |> halt()

      {:error, reason} ->
        {m, f, args} = opts[:error_handler]

        halt(apply(m, f, [conn, reason | args]))
    end
  end

  defp echo_sec_websocket_protocol(conn) do
    case get_req_header(conn, "sec-websocket-protocol") do
      [protocols | _] ->
        case Plug.Conn.Utils.list(protocols) do
          [protocol | _] -> put_resp_header(conn, "sec-websocket-protocol", protocol)
          [] -> conn
        end

      [] ->
        conn
    end
  end
end
