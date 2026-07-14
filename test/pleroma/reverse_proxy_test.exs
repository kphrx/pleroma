# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxyTest do
  use Pleroma.Web.ConnCase
  import ExUnit.CaptureLog
  import Mox

  alias Pleroma.ReverseProxy
  alias Pleroma.ReverseProxy.ClientMock
  alias Plug.Conn

  setup_all do
    {:ok, _} = Registry.start_link(keys: :unique, name: ClientMock)
    :ok
  end

  setup :verify_on_exit!

  defp request_mock(invokes) do
    ClientMock
    |> expect(:request, fn :get, url, headers, _body, _opts ->
      Registry.register(ClientMock, url, 0)
      body = headers |> Enum.into(%{}) |> Jason.encode!()

      {:ok, 200,
       [
         {"content-type", "application/json"},
         {"content-length", byte_size(body) |> to_string()}
       ], %{url: url, body: body}}
    end)
    |> expect(:stream_body, invokes, fn %{url: url, body: body} = client ->
      case Registry.lookup(ClientMock, url) do
        [{_, 0}] ->
          Registry.update_value(ClientMock, url, &(&1 + 1))
          {:ok, body, client}

        [{_, 1}] ->
          Registry.unregister(ClientMock, url)
          :done
      end
    end)
  end

  describe "reverse proxy" do
    test "do not track successful request", %{conn: conn} do
      request_mock(2)
      url = "/success"

      conn = ReverseProxy.call(conn, url)

      assert conn.status == 200
      assert Cachex.get(:failed_proxy_url_cache, url) == {:ok, nil}
    end
  end

  test "use Pleroma's user agent in the request; don't pass the client's", %{conn: conn} do
    request_mock(2)

    conn =
      conn
      |> Plug.Conn.put_req_header("user-agent", "fake/1.0")
      |> ReverseProxy.call("/user-agent")

    # Convert the response to a map without relying on json_response
    body = conn.resp_body
    assert conn.status == 200
    response = Jason.decode!(body)
    assert response == %{"user-agent" => Pleroma.Application.user_agent()}
  end

  test "closed connection", %{conn: conn} do
    ClientMock
    |> expect(:request, fn :get, "/closed", _, _, _ -> {:ok, 200, [], %{}} end)
    |> expect(:stream_body, fn _ -> {:error, :closed} end)
    |> expect(:close, fn _ -> :ok end)

    conn = ReverseProxy.call(conn, "/closed")
    assert conn.halted
  end

  defp stream_mock(invokes, with_close? \\ false) do
    ClientMock
    |> expect(:request, fn :get, "/stream-bytes/" <> length, _, _, _ ->
      Registry.register(ClientMock, "/stream-bytes/" <> length, 0)

      {:ok, 200, [{"content-type", "application/octet-stream"}],
       %{url: "/stream-bytes/" <> length}}
    end)
    |> expect(:stream_body, invokes, fn %{url: "/stream-bytes/" <> length} = client ->
      max = String.to_integer(length)

      case Registry.lookup(ClientMock, "/stream-bytes/" <> length) do
        [{_, current}] when current < max ->
          Registry.update_value(
            ClientMock,
            "/stream-bytes/" <> length,
            &(&1 + 10)
          )

          {:ok, "0123456789", client}

        [{_, ^max}] ->
          Registry.unregister(ClientMock, "/stream-bytes/" <> length)
          :done
      end
    end)

    if with_close? do
      expect(ClientMock, :close, fn _ -> :ok end)
    end
  end

  describe "max_body" do
    test "length returns error if content-length more than option", %{conn: conn} do
      request_mock(0)

      assert capture_log(fn ->
               ReverseProxy.call(conn, "/huge-file", max_body_length: 4)
             end) =~
               "[error] Elixir.Pleroma.ReverseProxy: request to \"/huge-file\" failed: :body_too_large"

      assert {:ok, true} == Cachex.get(:failed_proxy_url_cache, "/huge-file")

      assert capture_log(fn ->
               ReverseProxy.call(conn, "/huge-file", max_body_length: 4)
             end) == ""
    end

    test "max_body_length returns error if streaming body more than that option", %{conn: conn} do
      stream_mock(3, true)

      assert capture_log(fn ->
               ReverseProxy.call(conn, "/stream-bytes/50", max_body_length: 30)
             end) =~
               "Elixir.Pleroma.ReverseProxy request to /stream-bytes/50 failed while reading/chunking: :body_too_large"
    end
  end

  describe "HEAD requests" do
    test "common", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :head, "/head", _, _, _ ->
        {:ok, 200, [{"content-type", "image/png"}]}
      end)

      conn = ReverseProxy.call(Map.put(conn, :method, "HEAD"), "/head")

      assert conn.status == 200
      assert Conn.get_resp_header(conn, "content-type") == ["image/png"]
      assert conn.resp_body == ""
    end
  end

  defp error_mock(status) when is_integer(status) do
    ClientMock
    |> expect(:request, fn :get, "/status/" <> _, _, _, _ ->
      {:error, status}
    end)
  end

  describe "returns error on" do
    test "500", %{conn: conn} do
      error_mock(500)
      url = "/status/500"

      capture_log(fn -> ReverseProxy.call(conn, url) end) =~
        "[error] Elixir.Pleroma.ReverseProxy: request to /status/500 failed with HTTP status 500"

      assert Cachex.get(:failed_proxy_url_cache, url) == {:ok, true}

      {:ok, ttl} = Cachex.ttl(:failed_proxy_url_cache, url)
      assert ttl <= 60_000
    end

    test "400", %{conn: conn} do
      error_mock(400)
      url = "/status/400"

      capture_log(fn -> ReverseProxy.call(conn, url) end) =~
        "[error] Elixir.Pleroma.ReverseProxy: request to /status/400 failed with HTTP status 400"

      assert Cachex.get(:failed_proxy_url_cache, url) == {:ok, true}
      assert Cachex.ttl(:failed_proxy_url_cache, url) == {:ok, nil}
    end

    test "403", %{conn: conn} do
      error_mock(403)
      url = "/status/403"

      capture_log(fn ->
        ReverseProxy.call(conn, url, failed_request_ttl: :timer.seconds(120))
      end) =~
        "[error] Elixir.Pleroma.ReverseProxy: request to /status/403 failed with HTTP status 403"

      {:ok, ttl} = Cachex.ttl(:failed_proxy_url_cache, url)
      assert ttl > 100_000
    end

    test "204", %{conn: conn} do
      url = "/status/204"
      expect(ClientMock, :request, fn :get, _url, _, _, _ -> {:ok, 204, [], %{}} end)

      capture_log(fn ->
        conn = ReverseProxy.call(conn, url)
        assert conn.resp_body == "Request failed: No Content"
        assert conn.halted
      end) =~
        "[error] Elixir.Pleroma.ReverseProxy: request to \"/status/204\" failed with HTTP status 204"

      assert Cachex.get(:failed_proxy_url_cache, url) == {:ok, true}
      assert Cachex.ttl(:failed_proxy_url_cache, url) == {:ok, nil}
    end
  end

  test "streaming", %{conn: conn} do
    stream_mock(21)
    conn = ReverseProxy.call(conn, "/stream-bytes/200")
    assert conn.state == :chunked
    assert byte_size(conn.resp_body) == 200
    assert Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]
  end

  defp headers_mock(_) do
    ClientMock
    |> expect(:request, fn :get, "/headers", headers, _, _ ->
      Registry.register(ClientMock, "/headers", 0)
      {:ok, 200, [{"content-type", "application/json"}], %{url: "/headers", headers: headers}}
    end)
    |> expect(:stream_body, 2, fn %{url: url, headers: headers} = client ->
      case Registry.lookup(ClientMock, url) do
        [{_, 0}] ->
          Registry.update_value(ClientMock, url, &(&1 + 1))
          headers = for {k, v} <- headers, into: %{}, do: {String.capitalize(k), v}
          {:ok, Jason.encode!(%{headers: headers}), client}

        [{_, 1}] ->
          Registry.unregister(ClientMock, url)
          :done
      end
    end)

    :ok
  end

  describe "keep request headers" do
    setup [:headers_mock]

    test "header passes", %{conn: conn} do
      conn =
        Conn.put_req_header(
          conn,
          "accept",
          "text/html"
        )
        |> ReverseProxy.call("/headers")

      body = conn.resp_body
      assert conn.status == 200
      response = Jason.decode!(body)
      headers = response["headers"]
      assert headers["Accept"] == "text/html"
    end

    test "header is filtered", %{conn: conn} do
      conn =
        Conn.put_req_header(
          conn,
          "accept-language",
          "en-US"
        )
        |> ReverseProxy.call("/headers")

      body = conn.resp_body
      assert conn.status == 200
      response = Jason.decode!(body)
      headers = response["headers"]
      refute headers["Accept-Language"]
    end
  end

  test "returns 400 on non GET, HEAD requests", %{conn: conn} do
    conn = ReverseProxy.call(Map.put(conn, :method, "POST"), "/ip")
    assert conn.status == 400
  end

  describe "cache resp headers" do
    test "add cache-control", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :get, "/cache", _, _, _ ->
        {:ok, 200, [{"ETag", "some ETag"}], %{}}
      end)
      |> expect(:stream_body, fn _ -> :done end)

      conn = ReverseProxy.call(conn, "/cache")
      assert {"cache-control", "public, max-age=1209600, immutable"} in conn.resp_headers
    end
  end

  defp disposition_headers_mock(headers, url \\ "/disposition") do
    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ ->
      Registry.register(ClientMock, url, 0)

      {:ok, 200, headers, %{url: url}}
    end)
    |> expect(:stream_body, 2, fn %{url: ^url} = client ->
      case Registry.lookup(ClientMock, url) do
        [{_, 0}] ->
          Registry.update_value(ClientMock, url, &(&1 + 1))
          {:ok, "", client}

        [{_, 1}] ->
          Registry.unregister(ClientMock, url)
          :done
      end
    end)
  end

  describe "response content disposition header" do
    test "not attachment", %{conn: conn} do
      disposition_headers_mock([
        {"content-type", "image/gif"},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-type", "image/gif"} in conn.resp_headers
      assert {"content-disposition", "inline; filename=\"inline.gif\""} in conn.resp_headers
    end

    test "forces inline for inline content types overriding upstream attachment", %{
      conn: conn
    } do
      disposition_headers_mock([
        {"content-type", "image/png"},
        {"content-disposition", "attachment; filename=\"filename.png\""},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      [disposition] = Conn.get_resp_header(conn, "content-disposition")
      assert String.starts_with?(disposition, "inline")
      refute String.starts_with?(disposition, "attachment")
    end

    test "forces inline based on content type even without a file extension in the url", %{
      conn: conn
    } do
      disposition_headers_mock(
        [
          {"content-type", "image/jpeg"},
          {"content-length", "0"}
        ],
        "/original"
      )

      conn = ReverseProxy.call(conn, "/original")

      [disposition] = Conn.get_resp_header(conn, "content-disposition")
      assert disposition == "inline; filename=\"inline.jpg\""
    end

    test "with content-disposition header", %{conn: conn} do
      disposition_headers_mock([
        {"content-disposition", "attachment; filename=\"filename.jpg\""},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-disposition", "attachment; filename=\"filename.jpg\""} in conn.resp_headers
    end

    test "with inline_content_types: true leaves upstream headers untouched", %{
      conn: conn
    } do
      # opt == true: the proxy must not synthesise or rewrite content-disposition.
      disposition_headers_mock([
        {"content-type", "image/png"},
        {"content-disposition", "attachment; filename=\"upstream.png\""},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition", inline_content_types: true)

      assert {"content-disposition", "attachment; filename=\"upstream.png\""} in conn.resp_headers
    end

    test "with inline_content_types: true does not synthesise inline when upstream is absent", %{
      conn: conn
    } do
      disposition_headers_mock([
        {"content-type", "image/png"},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition", inline_content_types: true)

      assert Conn.get_resp_header(conn, "content-disposition") == []
    end

    test "with inline_content_types: false forces attachment for everything", %{
      conn: conn
    } do
      disposition_headers_mock([
        {"content-type", "image/png"},
        {"content-disposition", "inline; filename=\"pic.png\""},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition", inline_content_types: false)

      [disposition] = Conn.get_resp_header(conn, "content-disposition")
      assert String.starts_with?(disposition, "attachment")
    end

    test "with inline_content_types: false derives attachment filename from the URL basename when no upstream filename", %{
      conn: conn
    } do
      # No content-disposition header: the attachment branch falls back to
      # attachment_name, which by default comes from MediaProxy.filename/1
      # (the URL basename).
      disposition_headers_mock([
        {"content-type", "image/png"},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition", inline_content_types: false)

      [disposition] = Conn.get_resp_header(conn, "content-disposition")
      assert disposition == "attachment; filename=\"disposition\""
    end

    test "with inline_content_types: false honours an explicit attachment_name opt", %{
      conn: conn
    } do
      disposition_headers_mock([
        {"content-type", "image/png"},
        {"content-length", "0"}
      ])

      conn =
        ReverseProxy.call(conn, "/disposition",
          inline_content_types: false,
          attachment_name: "custom.bin"
        )

      [disposition] = Conn.get_resp_header(conn, "content-disposition")
      assert disposition == "attachment; filename=\"custom.bin\""
    end

    test "forces bare inline for a whitelisted type with no MIME extension", %{
      conn: conn
    } do
      # image/x-foo-bar has no entry in MIME's database, so inline_filename/1
      # returns nil and the disposition should be the bare token "inline".
      disposition_headers_mock([
        {"content-type", "image/x-foo-bar"},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition", inline_content_types: ["image/x-foo-bar"])

      [disposition] = Conn.get_resp_header(conn, "content-disposition")
      assert disposition == "inline"
    end

    test "honours a custom inline_content_types whitelist", %{conn: conn} do
      # image/bmp is NOT in the default whitelist; with a custom whitelist
      # that includes it, the proxy should force inline.
      disposition_headers_mock([
        {"content-type", "image/bmp"},
        {"content-disposition", "attachment; filename=\"upstream.bmp\""},
        {"content-length", "0"}
      ])

      conn =
        ReverseProxy.call(conn, "/disposition", inline_content_types: ["image/bmp"])

      [disposition] = Conn.get_resp_header(conn, "content-disposition")
      assert String.starts_with?(disposition, "inline")
      assert String.ends_with?(disposition, "inline.bmp\"")
    end

    test "treats a type outside the whitelist as attachment even on custom whitelist", %{
      conn: conn
    } do
      disposition_headers_mock([
        {"content-type", "image/png"},
        {"content-disposition", "attachment; filename=\"filename.png\""},
        {"content-length", "0"}
      ])

      conn =
        ReverseProxy.call(conn, "/disposition", inline_content_types: ["image/bmp"])

      assert {"content-disposition", "attachment; filename=\"filename.png\""} in conn.resp_headers
    end
  end

  describe "content-type sanitisation" do
    test "preserves allowed image type", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :get, "/content", _, _, _ ->
        {:ok, 200, [{"content-type", "image/png"}], %{url: "/content"}}
      end)
      |> expect(:stream_body, fn _ -> :done end)

      conn = ReverseProxy.call(conn, "/content")

      assert conn.status == 200
      assert Conn.get_resp_header(conn, "content-type") == ["image/png"]
    end

    test "preserves allowed video type", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :get, "/content", _, _, _ ->
        {:ok, 200, [{"content-type", "video/mp4"}], %{url: "/content"}}
      end)
      |> expect(:stream_body, fn _ -> :done end)

      conn = ReverseProxy.call(conn, "/content")

      assert conn.status == 200
      assert Conn.get_resp_header(conn, "content-type") == ["video/mp4"]
    end

    test "sanitizes ActivityPub content type", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :get, "/content", _, _, _ ->
        {:ok, 200, [{"content-type", "application/activity+json"}], %{url: "/content"}}
      end)
      |> expect(:stream_body, fn _ -> :done end)

      conn = ReverseProxy.call(conn, "/content")

      assert conn.status == 200
      assert Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end

    test "sanitizes LD-JSON content type", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :get, "/content", _, _, _ ->
        {:ok, 200, [{"content-type", "application/ld+json"}], %{url: "/content"}}
      end)
      |> expect(:stream_body, fn _ -> :done end)

      conn = ReverseProxy.call(conn, "/content")

      assert conn.status == 200
      assert Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end
  end

  # Hackney is used for Reverse Proxy when Hackney or Finch is the Tesla Adapter
  # Gun is able to proxy through Tesla, so it does not need testing as the
  # test cases in the Pleroma.HTTPTest module are sufficient
  describe "Hackney URL encoding:" do
    setup do
      ClientMock
      |> expect(:request, fn
        :get,
        "https://example.com/emoji/Pack%201/koronebless.png?foo=bar+baz",
        _headers,
        _body,
        _opts ->
          {:ok, 200, [{"content-type", "image/png"}], "It works!"}

        :get,
        "https://example.com/media/foo/bar%20!$&'()*+,;=/:%20@a%20%5Bbaz%5D.mp4",
        _headers,
        _body,
        _opts ->
          {:ok, 200, [{"content-type", "video/mp4"}], "Allowed reserved chars."}

        :get, "https://example.com/media/unicode%20%F0%9F%99%82%20.gif", _headers, _body, _opts ->
          {:ok, 200, [{"content-type", "image/gif"}], "Unicode emoji in path"}
      end)
      |> stub(:stream_body, fn _ -> :done end)
      |> stub(:close, fn _ -> :ok end)

      :ok
    end

    test "properly encodes URLs with spaces", %{conn: conn} do
      url_with_space = "https://example.com/emoji/Pack 1/koronebless.png?foo=bar baz"

      result = ReverseProxy.call(conn, url_with_space)

      assert result.status == 200
    end

    test "properly encoded URL should not be altered", %{conn: conn} do
      properly_encoded_url = "https://example.com/emoji/Pack%201/koronebless.png?foo=bar+baz"

      result = ReverseProxy.call(conn, properly_encoded_url)

      assert result.status == 200
    end

    test "properly encodes URLs with allowed reserved characters", %{conn: conn} do
      url_with_reserved_chars = "https://example.com/media/foo/bar !$&'()*+,;=/: @a [baz].mp4"

      result = ReverseProxy.call(conn, url_with_reserved_chars)

      assert result.status == 200
    end

    test "properly encodes URLs with unicode in path", %{conn: conn} do
      url_with_unicode = "https://example.com/media/unicode 🙂 .gif"

      result = ReverseProxy.call(conn, url_with_unicode)

      assert result.status == 200
    end
  end
end
