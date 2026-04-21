# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.FaviconPlugTest do
  use Pleroma.Web.ConnCase

  @dir "test/tmp/favicon_static"

  setup do
    Pleroma.Backports.mkdir_p!(@dir)

    on_exit(fn -> File.rm_rf!(@dir) end)
  end

  describe "default favicon" do
    test "returns favicon", %{conn: conn} do
      conn = get(conn, "/favicon.png")
      body_size = byte_size(conn.resp_body)

      assert conn.status == 200
      assert body_size == 1583
      assert response_content_type(conn, :png)
    end

    test "returns correct cache-control", %{conn: conn} do
      conn = get(conn, "/favicon.png")
      cache = get_resp_header(conn, "cache-control")

      assert conn.status == 200
      assert cache == ["public, max=age=86400, immutable"]
    end
  end

  describe "custom favicon" do
    setup do
      favicon_path = Path.join(@dir, "favicon.png")
      donor_image = "test/fixtures/image.png"

      File.cp!(donor_image, favicon_path)
      clear_config([:instance, :static_dir], @dir)

      on_exit(fn -> File.rm!(favicon_path) end)
    end

    test "returns favicon", %{conn: conn} do
      conn = get(conn, "/favicon.png")
      body_size = byte_size(conn.resp_body)

      assert conn.status == 200
      assert body_size == 104_426
      assert response_content_type(conn, :png)
    end

    test "returns correct cache-control", %{conn: conn} do
      conn = get(conn, "/favicon.png")
      cache = get_resp_header(conn, "cache-control")

      assert conn.status == 200
      assert cache == ["public, max=age=86400, immutable"]
    end
  end
end
