# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.CastAndValidateTest do
  use Pleroma.Web.ConnCase, async: false

  describe "permissive mode" do
    setup do: clear_config([Pleroma.Web.ApiSpec.CastAndValidate, :strict], false)

    test "drops several unexpected query params", %{conn: conn} do
      assert conn
             |> get("/api/v1/timelines/public?foo=1&bar=2&baz=3&local=true")
             |> json_response_and_validate_schema(200)
    end

    test "still rejects an invalid known param", %{conn: conn} do
      assert %{"error" => _} =
               conn
               |> get("/api/v1/timelines/public?foo=1&bar=2&limit=lots")
               |> json_response(400)
    end
  end
end
