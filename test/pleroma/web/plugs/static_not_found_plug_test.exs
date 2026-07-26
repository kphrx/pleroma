# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only
defmodule Pleroma.Web.Plugs.StaticNotFoundPlugTest do
  use Pleroma.Web.ConnCase

  describe "404s for missing files in static-only paths" do
    test "returns 404 for non-existent static-only JSON files" do
      conn = get(build_conn(), "/static/non-existent.json")

      assert conn.status == 404
      assert ["application/json"] = get_resp_header(conn, "content-type")
      assert Jason.decode!(conn.resp_body) == %{"error" => "not found"}
    end

    test "returns 404 for non-existent static-only non-JSON files" do
      conn = get(build_conn(), "/static/non-existent.txt")

      assert conn.status == 404
      assert conn.resp_body == "Not found"
      assert ["text/plain"] = get_resp_header(conn, "content-type")
    end

    test "returns 404 for non-existent .css files" do
      conn = get(build_conn(), "/static/non-existent.css")

      assert conn.status == 404
      assert conn.resp_body == "Not found"
      # Verifies that we forced text/plain for the error body, even though the path was .css
      assert ["text/plain"] = get_resp_header(conn, "content-type")
    end

    test "returns 404 for non-existent files without an extension" do
      conn = get(build_conn(), "/static/non-existent")

      assert conn.status == 404
      assert conn.resp_body == "Not found"
      assert ["text/plain"] = get_resp_header(conn, "content-type")
    end

    test "returns 200 (falls through to SPA) for non-static-only paths" do
      # /some-route is NOT in static_only_files, so it should still fall through to the SPA.
      conn = get(build_conn(), "/some-route")

      assert conn.status == 200
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
    end
  end
end
