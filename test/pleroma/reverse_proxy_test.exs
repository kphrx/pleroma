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

  defmodule ProxyPlug do
    @moduledoc false

    def init(options), do: options

    def call(conn, {url, opts}), do: Pleroma.ReverseProxy.call(conn, url, opts)
    def call(conn, url), do: Pleroma.ReverseProxy.call(conn, url)
  end

  setup_all do
    {:ok, _} = Registry.start_link(keys: :unique, name: ClientMock)
    :ok
  end

  setup :verify_on_exit!

  defp start_bandit(url, opts \\ []) do
    start_supervised!(
      {Bandit,
       plug: {ProxyPlug, {url, opts}},
       ip: {127, 0, 0, 1},
       port: 0,
       http_options: [log_exceptions_with_status_codes: []]}
    )
  end

  defp start_cowboy(url, opts \\ []) do
    ref = {__MODULE__, make_ref()}

    {:ok, _pid} =
      Plug.Cowboy.http(ProxyPlug, {url, opts},
        ip: {127, 0, 0, 1},
        port: 0,
        ref: ref,
        protocol_options: [stream_handlers: [:cowboy_stream_h]]
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    :ranch.get_port(ref)
  end

  defp bandit_request(url, headers \\ [], opts \\ []) do
    pid = start_bandit(url, opts)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    http1_request(port, headers)
  end

  defp cowboy_request(url, headers \\ [], opts \\ []) do
    url
    |> start_cowboy(opts)
    |> http1_request(headers)
  end

  defp http1_request(port, headers) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    request_headers =
      [["host: localhost", "connection: close"] | headers]
      |> List.flatten()
      |> Enum.join("\r\n")

    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\n#{request_headers}\r\n\r\n")
    recv_all(socket, [])
  end

  defp recv_all(socket, chunks) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, [data | chunks])
      {:error, reason} -> {reason, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp receive_mint_responses(conn, responses \\ []) do
    receive do
      message ->
        case Mint.HTTP2.stream(conn, message) do
          {:ok, conn, new_responses} ->
            responses = responses ++ new_responses

            if Enum.any?(new_responses, fn response ->
                 elem(response, 0) in [:done, :error]
               end) do
              responses
            else
              receive_mint_responses(conn, responses)
            end

          {:error, _conn, error, new_responses} ->
            responses ++ new_responses ++ [{:connection_error, error}]

          :unknown ->
            receive_mint_responses(conn, responses)
        end
    after
      2_000 -> responses ++ [:timeout]
    end
  end

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

  defp stream_then_error_mock(url, headers, chunk \\ "partial", error \\ :closed) do
    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ ->
      Registry.register(ClientMock, url, 0)
      {:ok, 200, headers, %{url: url}}
    end)
    |> expect(:stream_body, 2, fn %{url: ^url} = client ->
      case Registry.lookup(ClientMock, url) do
        [{_, 0}] ->
          Registry.update_value(ClientMock, url, &(&1 + 1))
          {:ok, chunk, client}

        [{_, 1}] ->
          Registry.unregister(ClientMock, url)
          {:error, error}
      end
    end)
    |> expect(:close, fn _ -> :ok end)
  end

  defp complete_stream_mock(url, headers, body) do
    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ ->
      Registry.register(ClientMock, url, 0)
      {:ok, 200, headers, %{url: url}}
    end)
    |> expect(:stream_body, 2, fn %{url: ^url} = client ->
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

  test "aborts a partially streamed response when the upstream closes", %{conn: conn} do
    stream_then_error_mock("/closed", [{"content-length", "20"}])

    assert_raise ReverseProxy.StreamError, fn ->
      ReverseProxy.call(conn, "/closed")
    end

    assert Cachex.get(:failed_proxy_url_cache, "/closed") == {:ok, true}
  end

  describe "Bandit HTTP/1 streaming" do
    test "closes an incomplete chunked response without a terminating chunk" do
      Mox.set_mox_global(ClientMock)
      stream_then_error_mock("/bandit-closed", [{"content-type", "image/png"}])

      assert {:closed, response} = bandit_request("/bandit-closed")
      assert response =~ "transfer-encoding: chunked"
      assert response =~ "partial"
      refute response =~ "0\r\n\r\n"
    end

    test "closes an incomplete fixed-length response before the declared length" do
      Mox.set_mox_global(ClientMock)

      stream_then_error_mock("/bandit-fixed-closed", [
        {"content-length", "20"},
        {"content-type", "image/png"}
      ])

      assert {:closed, response} = bandit_request("/bandit-fixed-closed")
      assert response =~ "content-length: 20"
      refute response =~ "transfer-encoding"
      assert String.ends_with?(response, "partial")
    end

    test "streams a complete fixed-length response without transformation" do
      Mox.set_mox_global(ClientMock)
      body = "complete body"

      complete_stream_mock(
        "/bandit-complete",
        [
          {"content-length", to_string(byte_size(body))},
          {"content-type", "image/png"}
        ],
        body
      )

      assert {:closed, response} =
               bandit_request("/bandit-complete", ["accept-encoding: deflate"])

      assert response =~ "content-length: #{byte_size(body)}"
      assert response =~ "cache-control: public, max-age=1209600, immutable, no-transform"
      refute response =~ "content-encoding: gzip"
      refute response =~ "content-encoding: deflate"
      assert String.ends_with?(response, body)
    end

    test "keeps no-transform when custom response headers replace cache-control" do
      Mox.set_mox_global(ClientMock)
      body = "complete body"

      complete_stream_mock(
        "/bandit-custom-cache-control",
        [
          {"content-length", to_string(byte_size(body))},
          {"content-type", "image/png"}
        ],
        body
      )

      assert {:closed, response} =
               bandit_request(
                 "/bandit-custom-cache-control",
                 ["accept-encoding: deflate"],
                 resp_headers: [{"cache-control", "private, max-age=60"}]
               )

      assert response =~ "content-length: #{byte_size(body)}"
      assert response =~ "cache-control: private, max-age=60, no-transform"
      refute response =~ "content-encoding: gzip"
      refute response =~ "content-encoding: deflate"
      assert String.ends_with?(response, body)
    end

    test "does not blacklist the upstream when the downstream disconnects" do
      Mox.set_mox_global(ClientMock)
      test_pid = self()

      ClientMock
      |> expect(:request, fn :get, "/bandit-client-closed", _, _, _ ->
        {:ok, 200, [{"content-type", "image/png"}], %{url: "/bandit-client-closed"}}
      end)
      |> stub(:stream_body, fn client ->
        send(test_pid, {:stream_requested, self()})

        receive do
          :continue -> {:ok, :binary.copy("x", 1_000_000), client}
        after
          1_000 -> raise "timed out waiting for downstream disconnect"
        end
      end)
      |> expect(:close, fn _ ->
        send(test_pid, :upstream_closed)
        :ok
      end)

      pid = start_bandit("/bandit-client-closed")
      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n")

      assert_receive {:stream_requested, request_pid}
      :ok = :inet.setopts(socket, linger: {true, 0})
      :ok = :gen_tcp.close(socket)
      send(request_pid, :continue)

      assert_receive :upstream_closed
      assert Cachex.get(:failed_proxy_url_cache, "/bandit-client-closed") == {:ok, nil}
    end
  end

  describe "Cowboy streaming" do
    test "closes an incomplete HTTP/1 chunked response without a terminating chunk" do
      Mox.set_mox_global(ClientMock)
      stream_then_error_mock("/cowboy-closed", [{"content-type", "image/png"}])

      assert {:closed, response} = cowboy_request("/cowboy-closed")
      assert response =~ "transfer-encoding: chunked"
      assert response =~ "partial"
      refute response =~ "0\r\n\r\n"
    end

    test "closes an incomplete HTTP/1 fixed-length response before the declared length" do
      Mox.set_mox_global(ClientMock)

      stream_then_error_mock("/cowboy-fixed-closed", [
        {"content-length", "20"},
        {"content-type", "image/png"}
      ])

      assert {:closed, response} = cowboy_request("/cowboy-fixed-closed")
      assert response =~ "content-length: 20"
      refute response =~ "transfer-encoding"
      assert String.ends_with?(response, "partial")
    end

    test "resets an incomplete HTTP/2 stream" do
      Mox.set_mox_global(ClientMock)
      stream_then_error_mock("/cowboy-http2-closed", [{"content-type", "image/png"}])

      port = start_cowboy("/cowboy-http2-closed")
      {:ok, mint} = Mint.HTTP2.connect(:http, "localhost", port)
      {:ok, mint, request_ref} = Mint.HTTP2.request(mint, "GET", "/", [], nil)
      responses = receive_mint_responses(mint)

      assert {:status, request_ref, 200} in responses
      assert {:data, request_ref, "partial"} in responses

      assert Enum.any?(responses, fn
               {:error, ^request_ref, %Mint.HTTPError{reason: {:server_closed_request, _}}} ->
                 true

               _ ->
                 false
             end)

      refute {:done, request_ref} in responses
      refute :timeout in responses
    end
  end

  test "resets an incomplete Bandit HTTP/2 stream" do
    Mox.set_mox_global(ClientMock)
    stream_then_error_mock("/bandit-http2-closed", [{"content-type", "image/png"}])

    pid = start_bandit("/bandit-http2-closed")
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    {:ok, mint} = Mint.HTTP2.connect(:http, "localhost", port)
    {:ok, mint, request_ref} = Mint.HTTP2.request(mint, "GET", "/", [], nil)
    responses = receive_mint_responses(mint)

    assert {:status, request_ref, 200} in responses
    assert {:data, request_ref, "partial"} in responses

    assert Enum.any?(responses, fn
             {:error, ^request_ref,
              %Mint.HTTPError{reason: {:server_closed_request, :internal_error}}} ->
               true

             _ ->
               false
           end)

    refute {:done, request_ref} in responses
    refute :timeout in responses
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
      expect(ClientMock, :close, fn _ -> :ok end)

      assert capture_log(fn ->
               ReverseProxy.call(conn, "/huge-file", max_body_length: 4)
             end) =~
               "[error] Elixir.Pleroma.ReverseProxy: request to \"/huge-file\" failed: :body_too_large"

      assert {:ok, true} == Cachex.get(:failed_proxy_url_cache, "/huge-file")

      assert capture_log(fn ->
               ReverseProxy.call(conn, "/huge-file", max_body_length: 4)
             end) == ""
    end

    test "closes streamed responses with invalid status", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :get, "/invalid-status", _, _, _ ->
        {:ok, 404, [], %{url: "/invalid-status"}}
      end)
      |> expect(:close, fn %{url: "/invalid-status"} -> :ok end)

      ReverseProxy.call(conn, "/invalid-status")
    end

    test "max_body_length returns error if streaming body more than that option", %{conn: conn} do
      stream_mock(3, true)

      log =
        capture_log(fn ->
          assert_raise ReverseProxy.StreamError, fn ->
            ReverseProxy.call(conn, "/stream-bytes/50", max_body_length: 29)
          end
        end)

      assert log =~
               "Elixir.Pleroma.ReverseProxy request to /stream-bytes/50 failed while reading/chunking: :body_too_large"
    end

    test "max_body_length accepts a body exactly at the limit", %{conn: conn} do
      stream_mock(4)

      conn = ReverseProxy.call(conn, "/stream-bytes/30", max_body_length: 30)
      assert byte_size(conn.resp_body) == 30
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

    test "rejects a malformed content-length", %{conn: conn} do
      url = "/head-invalid-content-length"

      expect(ClientMock, :request, fn :head, ^url, _, _, _ ->
        {:ok, 200, [{"content-length", "20junk"}]}
      end)

      conn = ReverseProxy.call(Map.put(conn, :method, "HEAD"), url)

      assert conn.status == 500
      assert Cachex.get(:failed_proxy_url_cache, url) == {:ok, true}
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

      ClientMock
      |> expect(:request, fn :get, _url, _, _, _ -> {:ok, 204, [], %{}} end)
      |> expect(:close, fn %{} -> :ok end)

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

  test "preserves a generic content type for a non-image body", %{conn: conn} do
    body = "not an image"

    ClientMock
    |> expect(:request, fn :get, "/extensionless", _, _, _ ->
      {:ok, 200, [], %{body: body}}
    end)
    |> expect(:stream_body, fn %{body: ^body} = client ->
      {:ok, body, Map.delete(client, :body)}
    end)
    |> expect(:stream_body, fn %{} -> :done end)

    conn = ReverseProxy.call(conn, "/extensionless", sniff_content_type: true)

    assert conn.resp_body == body
    assert Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]

    assert Conn.get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"extensionless\""
           ]
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

      assert {"cache-control", "public, max-age=1209600, immutable, no-transform"} in conn.resp_headers
    end

    test "preserves a valid upstream content-length", %{conn: conn} do
      body = "complete body"

      ClientMock
      |> expect(:request, fn :get, "/content-length", _, _, _ ->
        {:ok, 200, [{"content-length", to_string(byte_size(body))}], %{body: body}}
      end)
      |> expect(:stream_body, fn %{body: ^body} = client ->
        {:ok, body, Map.delete(client, :body)}
      end)
      |> expect(:stream_body, fn %{} -> :done end)

      conn = ReverseProxy.call(conn, "/content-length")

      assert Conn.get_resp_header(conn, "content-length") == [to_string(byte_size(body))]
    end

    test "rejects malformed upstream content-length values" do
      Enum.each(["20junk", "-1"], fn content_length ->
        url = "/invalid-content-length/#{content_length}"

        ClientMock
        |> expect(:request, fn :get, ^url, _, _, _ ->
          {:ok, 200, [{"content-length", content_length}], %{url: url}}
        end)
        |> expect(:close, fn %{url: ^url} -> :ok end)

        conn = ReverseProxy.call(build_conn(), url)

        assert conn.status == 500
        assert Cachex.get(:failed_proxy_url_cache, url) == {:ok, true}
      end)
    end

    test "rejects conflicting upstream content-length values" do
      url = "/conflicting-content-length"

      ClientMock
      |> expect(:request, fn :get, ^url, _, _, _ ->
        {:ok, 200, [{"content-length", "7"}, {"content-length", "20"}], %{url: url}}
      end)
      |> stub(:stream_body, fn _ -> :done end)
      |> stub(:close, fn _ -> :ok end)

      conn = ReverseProxy.call(build_conn(), url)

      assert conn.status == 500
      assert Cachex.get(:failed_proxy_url_cache, url) == {:ok, true}
    end

    test "normalizes equivalent upstream content-length values", %{conn: conn} do
      body = "partial"

      complete_stream_mock(
        "/duplicate-content-length",
        [{"content-length", "7"}, {"content-length", "07"}],
        body
      )

      conn = ReverseProxy.call(conn, "/duplicate-content-length")

      assert Conn.get_resp_header(conn, "content-length") == ["7"]
      assert conn.resp_body == body
    end
  end

  defp disposition_headers_mock(headers) do
    ClientMock
    |> expect(:request, fn :get, "/disposition", _, _, _ ->
      Registry.register(ClientMock, "/disposition", 0)

      {:ok, 200, headers, %{url: "/disposition"}}
    end)
    |> expect(:stream_body, 2, fn %{url: "/disposition"} = client ->
      case Registry.lookup(ClientMock, "/disposition") do
        [{_, 0}] ->
          Registry.update_value(ClientMock, "/disposition", &(&1 + 1))
          {:ok, "", client}

        [{_, 1}] ->
          Registry.unregister(ClientMock, "/disposition")
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
    end

    test "with content-disposition header", %{conn: conn} do
      disposition_headers_mock([
        {"content-disposition", "attachment; filename=\"filename.jpg\""},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-disposition", "attachment; filename=\"filename.jpg\""} in conn.resp_headers
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
