# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MediaProxy.MediaProxyControllerTest do
  use Pleroma.Web.ConnCase

  import Mock
  import Mox

  alias Pleroma.ReverseProxy.ClientMock
  alias Pleroma.UnstubbedConfigMock, as: ConfigMock
  alias Pleroma.Web.MediaProxy
  alias Plug.Conn

  setup do
    ConfigMock
    |> stub_with(Pleroma.Test.StaticConfig)

    :ok
  end

  describe "Media Proxy" do
    setup do
      clear_config([:media_proxy, :enabled], true)
      clear_config([Pleroma.Web.Endpoint, :secret_key_base], "00000000000")

      [url: MediaProxy.encode_url("https://google.fn/test.png")]
    end

    test "it returns 404 when disabled", %{conn: conn} do
      clear_config([:media_proxy, :enabled], false)

      assert %Conn{
               status: 404,
               resp_body: "Not Found"
             } = get(conn, "/proxy/hhgfh/eeeee")

      assert %Conn{
               status: 404,
               resp_body: "Not Found"
             } = get(conn, "/proxy/hhgfh/eeee/fff")
    end

    test "it returns 403 for invalid signature", %{conn: conn, url: url} do
      clear_config([Pleroma.Web.Endpoint, :secret_key_base], "000")
      %{path: path} = URI.parse(url)

      assert %Conn{
               status: 403,
               resp_body: "Forbidden"
             } = get(conn, path)

      assert %Conn{
               status: 403,
               resp_body: "Forbidden"
             } = get(conn, "/proxy/hhgfh/eeee")

      assert %Conn{
               status: 403,
               resp_body: "Forbidden"
             } = get(conn, "/proxy/hhgfh/eeee/fff")
    end

    test "redirects to valid url when filename is invalidated", %{conn: conn, url: url} do
      invalid_url = String.replace(url, "test.png", "test-file.png")
      response = get(conn, invalid_url)
      assert response.status == 302
      assert redirected_to(response) == url
    end

    test "it performs ReverseProxy.call with valid signature", %{conn: conn, url: url} do
      with_mock Pleroma.ReverseProxy,
        call: fn _conn, _url, _opts -> %Conn{status: :success} end do
        assert %Conn{status: :success} = get(conn, url)
      end
    end

    test "it returns 404 when url is in banned_urls cache", %{conn: conn, url: url} do
      MediaProxy.put_in_banned_urls("https://google.fn/test.png")

      with_mock Pleroma.ReverseProxy,
        call: fn _conn, _url, _opts -> %Conn{status: :success} end do
        assert %Conn{status: 404, resp_body: "Not Found"} = get(conn, url)
      end
    end

    test "it applies sandbox CSP to MediaProxy requests", %{conn: conn} do
      media_url = "https://lain.com/image.png"
      media_proxy_url = MediaProxy.encode_url(media_url)

      ClientMock
      |> expect(:request, fn :get, ^media_url, _, _, _ ->
        {:ok, 200, [{"content-type", "image/png"}]}
      end)

      %Conn{resp_headers: headers} = get(conn, media_proxy_url)

      assert {"content-security-policy", "sandbox;"} in headers
    end
  end

  describe "Media Preview Proxy" do
    def assert_dependencies_installed do
      missing_dependencies = Pleroma.Helpers.MediaHelper.missing_dependencies()

      assert missing_dependencies == [],
             "Error: missing dependencies (please refer to `docs/installation`): #{inspect(missing_dependencies)}"
    end

    setup do
      clear_config([:media_proxy, :enabled], true)
      clear_config([:media_preview_proxy, :enabled], true)
      clear_config([Pleroma.Web.Endpoint, :secret_key_base], "00000000000")

      original_url = "https://google.fn/test.png"

      [
        url: MediaProxy.encode_preview_url(original_url),
        media_proxy_url: MediaProxy.encode_url(original_url)
      ]
    end

    test "returns 404 when media proxy is disabled", %{conn: conn} do
      clear_config([:media_proxy, :enabled], false)

      assert %Conn{
               status: 404,
               resp_body: "Not Found"
             } = get(conn, "/proxy/preview/hhgfh/eeeee")

      assert %Conn{
               status: 404,
               resp_body: "Not Found"
             } = get(conn, "/proxy/preview/hhgfh/fff")
    end

    test "returns 404 when disabled", %{conn: conn} do
      clear_config([:media_preview_proxy, :enabled], false)

      assert %Conn{
               status: 404,
               resp_body: "Not Found"
             } = get(conn, "/proxy/preview/hhgfh/eeeee")

      assert %Conn{
               status: 404,
               resp_body: "Not Found"
             } = get(conn, "/proxy/preview/hhgfh/fff")
    end

    test "it returns 403 for invalid signature", %{conn: conn, url: url} do
      clear_config([Pleroma.Web.Endpoint, :secret_key_base], "000")
      %{path: path} = URI.parse(url)

      assert %Conn{
               status: 403,
               resp_body: "Forbidden"
             } = get(conn, path)

      assert %Conn{
               status: 403,
               resp_body: "Forbidden"
             } = get(conn, "/proxy/preview/hhgfh/eeee")

      assert %Conn{
               status: 403,
               resp_body: "Forbidden"
             } = get(conn, "/proxy/preview/hhgfh/eeee/fff")
    end

    test "redirects to valid url when filename is invalidated", %{conn: conn, url: url} do
      invalid_url = String.replace(url, "test.png", "test-file.png")
      response = get(conn, invalid_url)
      assert response.status == 302
      assert redirected_to(response) == url
    end

    test "responds with 424 Failed Dependency if HEAD request to media proxy fails", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{status: 500, body: ""}
      end)

      response = get(conn, url)
      assert response.status == 424
      assert response.resp_body == "Can't fetch HTTP headers (HTTP 500)."
    end

    test "redirects to media proxy URI on unsupported content type", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: "", headers: [{"content-type", "application/pdf"}]}
      end)

      response = get(conn, url)
      assert response.status == 302
      assert redirected_to(response) == media_proxy_url
    end

    test "with `static=true` and GIF image preview requested, responds with JPEG image", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      assert_dependencies_installed()

      # Setting a high :min_content_length to ensure this scenario is not affected by its logic
      clear_config([:media_preview_proxy, :min_content_length], 1_000_000_000)

      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{
            status: 200,
            body: "",
            headers: [{"content-type", "image/gif"}, {"content-length", "1001718"}]
          }

        %{method: :get, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: File.read!("test/fixtures/image.gif")}
      end)

      response = get(conn, url <> "?static=true")

      assert response.status == 200
      assert Conn.get_resp_header(response, "content-type") == ["image/jpeg"]
      assert response.resp_body != ""
    end

    test "with GIF image preview requested and no `static` param, redirects to media proxy URI",
         %{
           conn: conn,
           url: url,
           media_proxy_url: media_proxy_url
         } do
      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: "", headers: [{"content-type", "image/gif"}]}
      end)

      response = get(conn, url)

      assert response.status == 301
      assert redirected_to(response, 301) == media_proxy_url
    end

    test "with `static` param and non-GIF image preview requested, responds with a preview",
         %{
           conn: conn,
           url: url,
           media_proxy_url: media_proxy_url
         } do
      assert_dependencies_installed()

      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: "", headers: [{"content-type", "image/jpeg"}]}

        %{method: :get, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: File.read!("test/fixtures/image.jpg")}
      end)

      response = get(conn, url <> "?static=true")

      assert response.status == 200
      assert Conn.get_resp_header(response, "content-type") == ["image/jpeg"]
      assert response.resp_body != ""
    end

    test "with :min_content_length setting not matched by Content-Length header, " <>
           "redirects to media proxy URI",
         %{
           conn: conn,
           url: url,
           media_proxy_url: media_proxy_url
         } do
      clear_config([:media_preview_proxy, :min_content_length], 100_000)

      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{
            status: 200,
            body: "",
            headers: [{"content-type", "image/gif"}, {"content-length", "5000"}]
          }
      end)

      response = get(conn, url)

      assert response.status == 301
      assert redirected_to(response, 301) == media_proxy_url
    end

    test "thumbnails PNG images into PNG", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      assert_dependencies_installed()

      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: "", headers: [{"content-type", "image/png"}]}

        %{method: :get, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: File.read!("test/fixtures/image.png")}
      end)

      response = get(conn, url)

      assert response.status == 200
      assert Conn.get_resp_header(response, "content-type") == ["image/png"]
      assert response.resp_body != ""
    end

    test "thumbnails JPEG images into JPEG", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      assert_dependencies_installed()

      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: "", headers: [{"content-type", "image/jpeg"}]}

        %{method: :get, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: File.read!("test/fixtures/image.jpg")}
      end)

      response = get(conn, url)

      assert response.status == 200
      assert Conn.get_resp_header(response, "content-type") == ["image/jpeg"]
      assert response.resp_body != ""
    end

    defp long_side(binary) do
      {:ok, image} = Vix.Vips.Image.new_from_buffer(binary)
      max(Vix.Vips.Image.width(image), Vix.Vips.Image.height(image))
    end

    defp mock_image(media_proxy_url, content_type, fixture) do
      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: "", headers: [{"content-type", content_type}]}

        %{method: :get, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: File.read!(fixture)}
      end)
    end

    test "without `size`, the preview fits the thumbnail dimensions", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      assert_dependencies_installed()
      mock_image(media_proxy_url, "image/jpeg", "test/fixtures/image.jpg")

      response = get(conn, url)

      assert response.status == 200
      assert long_side(response.resp_body) == 600
    end

    test "with a configured `size`, the preview fits that size", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      assert_dependencies_installed()
      clear_config([:media_preview_proxy, :image_sizes], [300, 800])
      mock_image(media_proxy_url, "image/jpeg", "test/fixtures/image.jpg")

      response = get(conn, url <> "?size=800")

      assert response.status == 200
      assert Conn.get_resp_header(response, "content-type") == ["image/jpeg"]
      assert long_side(response.resp_body) == 800
    end

    test "with a configured `size`, a PNG stays a PNG", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      assert_dependencies_installed()
      clear_config([:media_preview_proxy, :image_sizes], [300])
      mock_image(media_proxy_url, "image/png", "test/fixtures/image.png")

      response = get(conn, url <> "?size=300")

      assert response.status == 200
      assert Conn.get_resp_header(response, "content-type") == ["image/png"]
      assert long_side(response.resp_body) == 300
    end

    @avif_skip if(Pleroma.Helpers.MediaHelper.avif_supported?(),
                 do: false,
                 else: "this libvips cannot encode AVIF"
               )

    @tag skip: @avif_skip
    test "with AVIF on and accepted, a size comes as AVIF", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      clear_config([:media_preview_proxy, :image_sizes], [300])
      clear_config([:media_preview_proxy, :avif], true)
      mock_image(media_proxy_url, "image/jpeg", "test/fixtures/image.jpg")

      response =
        conn
        |> put_req_header("accept", "IMAGE/AVIF; q=0.5,image/webp,*/*")
        |> get(url <> "?size=300")

      assert response.status == 200
      assert Conn.get_resp_header(response, "content-type") == ["image/avif"]
      assert Conn.get_resp_header(response, "vary") == ["accept"]
      assert long_side(response.resp_body) == 300
    end

    @tag skip: @avif_skip
    test "with AVIF on and accepted, a PNG size comes as AVIF too", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      clear_config([:media_preview_proxy, :image_sizes], [300])
      clear_config([:media_preview_proxy, :avif], true)
      mock_image(media_proxy_url, "image/png", "test/fixtures/image.png")

      response =
        conn
        |> put_req_header("accept", "image/avif,*/*")
        |> get(url <> "?size=300")

      assert Conn.get_resp_header(response, "content-type") == ["image/avif"]
      assert long_side(response.resp_body) == 300
    end

    @tag skip: @avif_skip
    test "with AVIF on but not accepted, a size stays JPEG and varies on Accept", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      clear_config([:media_preview_proxy, :image_sizes], [300])
      clear_config([:media_preview_proxy, :avif], true)
      mock_image(media_proxy_url, "image/jpeg", "test/fixtures/image.jpg")

      response =
        conn
        |> put_req_header("accept", "image/webp,*/*")
        |> get(url <> "?size=300")

      assert Conn.get_resp_header(response, "content-type") == ["image/jpeg"]
      assert Conn.get_resp_header(response, "vary") == ["accept"]
    end

    @tag skip: @avif_skip
    test "AVIF requires an explicit media range with positive quality", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      clear_config([:media_preview_proxy, :image_sizes], [300])
      clear_config([:media_preview_proxy, :avif], true)
      mock_image(media_proxy_url, "image/jpeg", "test/fixtures/image.jpg")

      for accept <- [
            "image/avif;q=0,image/jpeg,*/*",
            "image/avif; q=0.000, image/*;q=1",
            "image/avif;q=invalid",
            "image/avif;q=0.5invalid",
            "image/avif;q=1.1",
            "image/avif-sequence,*/*",
            "image/jpeg; note=\"image/avif\""
          ] do
        response = conn |> put_req_header("accept", accept) |> get(url <> "?size=300")

        assert response.status == 200
        assert Conn.get_resp_header(response, "content-type") == ["image/jpeg"], accept
        assert Conn.get_resp_header(response, "vary") == ["accept"]
      end
    end

    test "with AVIF off, a size stays JPEG and does not vary", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      clear_config([:media_preview_proxy, :image_sizes], [300])
      clear_config([:media_preview_proxy, :avif], false)
      mock_image(media_proxy_url, "image/jpeg", "test/fixtures/image.jpg")

      response =
        conn
        |> put_req_header("accept", "image/avif,*/*")
        |> get(url <> "?size=300")

      assert Conn.get_resp_header(response, "content-type") == ["image/jpeg"]
      assert Conn.get_resp_header(response, "vary") == []
    end

    test "a thumbnail is never AVIF", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      clear_config([:media_preview_proxy, :avif], true)
      mock_image(media_proxy_url, "image/jpeg", "test/fixtures/image.jpg")

      response =
        conn
        |> put_req_header("accept", "image/avif,*/*")
        |> get(url)

      assert Conn.get_resp_header(response, "content-type") == ["image/jpeg"]
    end

    test "accepts a `size` only as written in the config", %{conn: conn, url: url} do
      clear_config([:media_preview_proxy, :image_sizes], [800])

      for size <- ["+800", "0800", "800.0", " 800", "800abc"] do
        response = get(conn, url <> "?size=" <> URI.encode_www_form(size))
        refute redirected_to(response, 302) =~ "size="
      end
    end

    test "redirects a `size` that is not a string", %{conn: conn, url: url} do
      clear_config([:media_preview_proxy, :image_sizes], [800])

      response = get(conn, url <> "?size[]=800")

      assert response.status == 302
    end

    test "with a `size` that is not configured, redirects to the preview without it", %{
      conn: conn,
      url: url
    } do
      clear_config([:media_preview_proxy, :image_sizes], [300])

      response = get(conn, url <> "?size=301")

      assert redirected_to(response, 302) =~ url
      refute redirected_to(response, 302) =~ "size="
    end

    test "redirects to media proxy URI in case of thumbnailing error", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: "", headers: [{"content-type", "image/jpeg"}]}

        %{method: :get, url: ^media_proxy_url} ->
          %Tesla.Env{status: 200, body: "<html><body>error</body></html>"}
      end)

      response = get(conn, url)

      assert response.status == 302
      assert redirected_to(response) == media_proxy_url
    end

    test "redirects to media proxy URI with 301 when image is too small for preview", %{
      conn: conn,
      url: url,
      media_proxy_url: media_proxy_url
    } do
      clear_config([:media_preview_proxy],
        enabled: true,
        min_content_length: 1000,
        image_quality: 85,
        thumbnail_max_width: 100,
        thumbnail_max_height: 100
      )

      Tesla.Mock.mock(fn
        %{method: :head, url: ^media_proxy_url} ->
          %Tesla.Env{
            status: 200,
            body: "",
            headers: [{"content-type", "image/png"}, {"content-length", "500"}]
          }
      end)

      response = get(conn, url)
      assert response.status == 301
      assert redirected_to(response, 301) == media_proxy_url
    end
  end
end
