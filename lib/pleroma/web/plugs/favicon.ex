# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.Favicon do
  @behaviour Plug

  @moduledoc """
  Serves favicon.png directly from the instance static directory,
  bypassing the frontend-specific logic.
  """

  import Plug.Conn, only: [put_resp_header: 3]

  def init(opts) do
    opts
    |> Keyword.put(:from, "__unconfigured_favicon_static_plug")
    |> Plug.Static.init()
  end

  def call(%{request_path: "/favicon.png"} = conn, opts) do
    case find_favicon_dir() do
      {:ok, dir} ->
        call_static(conn, opts, dir)

      :error ->
        conn # Let the request keep going to a 404
    end
  end

  def call(conn, _) do
    conn
  end

  defp find_favicon_dir() do
    instance_dir = Pleroma.Config.get([:instance, :static_dir], "instance/static")
    instance_path = Path.join(instance_dir, "favicon.png")

    priv_dir = Application.app_dir(:pleroma, "priv/static")
    priv_path = Path.join(priv_dir, "favicon.png")

    cond do
      File.exists?(instance_path) -> {:ok, instance_dir}
      File.exists?(priv_path) -> {:ok, priv_dir}
      true -> :error
    end
  end

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
