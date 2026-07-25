# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.StaticNotFoundPlug do
  @moduledoc """
  A small plug that enforces returning 404 on static files when they don't exist.
  """
  @behaviour Plug

  require Pleroma.Constants
  import Plug.Conn, only: [put_resp_header: 3, send_resp: 3, halt: 1]

  def init(opts), do: opts

  for only <- Pleroma.Constants.static_only_files() do
    def call(%{request_path: "/" <> unquote(only) <> _} = conn, _opts) do
      send_404(conn)
    end
  end

  def call(conn, _) do
    conn
  end

  defp send_404(conn) do
    if String.ends_with?(String.downcase(conn.request_path), ".json") do
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(404, Jason.encode!(%{error: "not found"}))
    else
      conn
      |> put_resp_header("content-type", "text/plain")
      |> send_resp(404, "Not found")
    end
    |> halt()
  end
end
