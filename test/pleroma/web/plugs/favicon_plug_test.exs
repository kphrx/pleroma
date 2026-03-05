# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.FaviconPlugTest do
  use Pleroma.Web.ConnCase

  # import Mox

  # alias Pleroma.UnstubbedConfigMock, as: ConfigMock

  @dir "test/tmp/favicon_static"

  describe "default favicon" do
    test "returns favicon", %{conn: conn} do
      conn = get(conn, "/favicon.png")
      etag = get_resp_header(conn, "etag")

      # etag changes when serving a different file
      assert conn.status == 200
      assert etag == ["\"72487CE\""]
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
      Pleroma.Backports.mkdir_p!(@dir)
      favicon_path = Path.join(@dir, "favicon.png")

      # Favicon plug should always return image/png
      donor_image = "test/fixtures/image.gif"
      image_stat = File.stat!(donor_image)

      # Preserve stat since that's what etag is based on
      File.cp!(donor_image, favicon_path)
      File.write_stat!(favicon_path, image_stat)

      clear_config([:instance, :static_dir], @dir)

      on_exit( fn -> File.rm_rf!(@dir) end)
    end

    test "returns favicon", %{conn: conn} do
      conn = get(conn, "/favicon.png")
      etag = get_resp_header(conn, "etag")

      assert conn.status == 200
      assert etag == ["\"215A3A4\""]
      assert response_content_type(conn, :png)
    end

    test "returns correct cache-control", %{conn: conn} do
      conn = get(conn ,"/favicon.png")
      cache = get_resp_header(conn, "cache-control")

      assert conn.status == 200
      assert cache == ["public, max=age=86400, immutable"]
    end
  end
end
