# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.Favicon do
  @behaviour Plug

  @moduledoc """
  Serves favicon.png directly from the instance static directory,
  bypassing the frontend-specific logic.
  """

  alias Pleroma.Web.Plugs.FrontendStatic
  import Plug.Conn, only: [put_resp_header: 3]

  def init(opts) do
    opts
    |> Keyword.put(:from, "__unconfigured_favicon_static_plug")
    |> Plug.Static.init()
  end

  def call(conn, opts) do
    if favicon_route?(conn.path_info) do
      case find_favicon_dir(conn) do
        {:ok, dir} ->
          call_static(conn, opts, dir)
          |> Plug.Conn.halt()

        :error ->
          conn # Let the request keep going to a 404
      end
    else
      conn
    end
  end

  defp find_favicon_dir(conn) do
    instance_dir = Pleroma.Config.get([:instance, :static_dir], "instance/static")
    instance_path = Path.join(instance_dir, "favicon.png")

    frontend_type = FrontendStatic.preferred_or_fallback(conn, :primary)
    frontend_dir = FrontendStatic.file_path("", frontend_type)
    frontend_path = if frontend_dir, do: Path.join(frontend_dir, "favicon.png"), else: nil

    priv_dir = Application.app_dir(:pleroma, "priv/static")
    priv_path = Path.join(priv_dir, "favicon.png")

    cond do
      File.exists?(instance_path) -> {:ok, instance_dir}
      frontend_path && File.exists?(frontend_path) -> {:ok, frontend_dir}
      File.exists?(priv_path) -> {:ok, priv_dir}
      true -> :error
    end
  end

  defp favicon_route?(["favicon.png"]), do: true
  defp favicon_route?(_), do: false

  defp call_static(conn, opts, from) do
    opts =
      opts
      |> Map.put(:from, from)
      |> Map.put(:content_types, false)

    conn = set_content_type(conn)

    Plug.Static.call(conn, opts)
  end

  defp set_content_type(conn) do
    put_resp_header(conn, "content-type", "image/png")
  end
end
