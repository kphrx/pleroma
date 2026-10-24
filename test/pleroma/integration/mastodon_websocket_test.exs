# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Integration.MastodonWebsocketTest do
  # Needs a streamer, needs to stay synchronous
  use Pleroma.DataCase

  import ExUnit.CaptureLog
  import Pleroma.Factory

  alias Pleroma.Integration.WebsocketClient
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.OAuth

  @moduletag needs_streamer: true, capture_log: true

  @path Pleroma.Web.Endpoint.url()
        |> URI.parse()
        |> Map.put(:scheme, "ws")
        |> Map.put(:path, "/api/v1/streaming")
        |> URI.to_string()

  def start_socket(qs \\ nil, headers \\ []) do
    path =
      case qs do
        nil -> @path
        qs -> @path <> qs
      end

    WebsocketClient.start_link(self(), path, headers)
  end

  defp raw_websocket_handshake(qs, headers) do
    uri = URI.parse(@path <> qs)
    port = uri.port || 80
    path = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")

    default_headers = [
      {"host", "#{uri.host}:#{port}"},
      {"upgrade", "websocket"},
      {"connection", "Upgrade"},
      {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))},
      {"sec-websocket-version", "13"}
    ]

    request = [
      "GET #{path} HTTP/1.1\r\n",
      Enum.map(default_headers ++ headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
      "\r\n"
    ]

    with {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(uri.host), port, [:binary, active: false], 1_000),
         :ok <- :gen_tcp.send(socket, request),
         {:ok, response} <- :gen_tcp.recv(socket, 0, 1_000) do
      :gen_tcp.close(socket)
      {:ok, parse_http_response(response)}
    end
  end

  defp parse_http_response(response) do
    [headers | _] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(headers, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    headers =
      Enum.map(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status), headers: headers}
  end

  defp decode_json(json) do
    with {:ok, %{"event" => event, "payload" => payload_text}} <- Jason.decode(json),
         {:ok, payload} <- Jason.decode(payload_text) do
      {:ok, %{"event" => event, "payload" => payload}}
    end
  end

  # Turns atom keys to strings
  defp atom_key_to_string(json) do
    json
    |> Jason.encode!()
    |> Jason.decode!()
  end

  test "refuses invalid requests" do
    capture_log(fn ->
      assert {:error, %WebSockex.RequestError{code: 404}} = start_socket("?stream=ncjdk")
      Process.sleep(30)
    end)
  end

  test "requires authentication and a valid token for protected streams" do
    capture_log(fn ->
      assert {:error, %WebSockex.RequestError{code: 401}} =
               start_socket("?stream=user&access_token=aaaaaaaaaaaa")

      assert {:error, %WebSockex.RequestError{code: 401}} = start_socket("?stream=user")
      Process.sleep(30)
    end)
  end

  test "allows unified stream" do
    assert {:ok, _} = start_socket()
  end

  test "allows public streams without authentication" do
    assert {:ok, _} = start_socket("?stream=public")
    assert {:ok, _} = start_socket("?stream=public:local")
    assert {:ok, _} = start_socket("?stream=public:remote&instance=lain.com")
    assert {:ok, _} = start_socket("?stream=hashtag&tag=lain")
  end

  test "receives well formatted events" do
    user = insert(:user)
    {:ok, _} = start_socket("?stream=public")
    {:ok, activity} = CommonAPI.post(user, %{status: "nice echo chamber"})

    assert_receive {:text, raw_json}, 1_000
    assert {:ok, json} = Jason.decode(raw_json)

    assert "update" == json["event"]
    assert json["payload"]
    assert {:ok, json} = Jason.decode(json["payload"])

    view_json = atom_key_to_string(StatusView.render("show.json", activity: activity, for: nil))

    assert json == view_json
  end

  describe "subscribing via WebSocket" do
    test "can subscribe" do
      user = insert(:user)
      {:ok, pid} = start_socket()
      WebsocketClient.send_text(pid, %{type: "subscribe", stream: "public"} |> Jason.encode!())
      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "success"}
              }} = decode_json(raw_json)

      {:ok, activity} = CommonAPI.post(user, %{status: "nice echo chamber"})

      assert_receive {:text, raw_json}, 1_000
      assert {:ok, json} = Jason.decode(raw_json)

      assert "update" == json["event"]
      assert json["payload"]
      assert {:ok, json} = Jason.decode(json["payload"])

      view_json = atom_key_to_string(StatusView.render("show.json", activity: activity, for: nil))

      assert json == view_json
    end

    test "can subscribe to multiple streams" do
      user = insert(:user)
      {:ok, pid} = start_socket()
      WebsocketClient.send_text(pid, %{type: "subscribe", stream: "public"} |> Jason.encode!())
      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "success"}
              }} = decode_json(raw_json)

      WebsocketClient.send_text(
        pid,
        %{type: "subscribe", stream: "hashtag", tag: "mew"} |> Jason.encode!()
      )

      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "success"}
              }} = decode_json(raw_json)

      {:ok, _activity} = CommonAPI.post(user, %{status: "nice echo chamber #mew"})

      assert_receive {:text, raw_json}, 1_000
      assert {:ok, %{"stream" => stream1}} = Jason.decode(raw_json)
      assert_receive {:text, raw_json}, 1_000
      assert {:ok, %{"stream" => stream2}} = Jason.decode(raw_json)

      streams = [stream1, stream2]
      assert ["hashtag", "mew"] in streams
      assert ["public"] in streams
    end

    test "won't double subscribe" do
      user = insert(:user)
      {:ok, pid} = start_socket()
      WebsocketClient.send_text(pid, %{type: "subscribe", stream: "public"} |> Jason.encode!())
      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "success"}
              }} = decode_json(raw_json)

      WebsocketClient.send_text(pid, %{type: "subscribe", stream: "public"} |> Jason.encode!())
      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "ignored"}
              }} = decode_json(raw_json)

      {:ok, _activity} = CommonAPI.post(user, %{status: "nice echo chamber"})

      assert_receive {:text, _}, 1_000
      refute_receive {:text, _}, 1_000
    end

    test "rejects invalid streams" do
      {:ok, pid} = start_socket()
      WebsocketClient.send_text(pid, %{type: "subscribe", stream: "nonsense"} |> Jason.encode!())
      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "error", "error" => "bad_topic"}
              }} = decode_json(raw_json)
    end

    test "can unsubscribe" do
      user = insert(:user)
      {:ok, pid} = start_socket()
      WebsocketClient.send_text(pid, %{type: "subscribe", stream: "public"} |> Jason.encode!())
      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "success"}
              }} = decode_json(raw_json)

      WebsocketClient.send_text(pid, %{type: "unsubscribe", stream: "public"} |> Jason.encode!())
      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "unsubscribe", "result" => "success"}
              }} = decode_json(raw_json)

      {:ok, _activity} = CommonAPI.post(user, %{status: "nice echo chamber"})
      refute_receive {:text, _}, 1_000
    end
  end

  describe "with a valid user token" do
    setup do
      {:ok, app} =
        Pleroma.Repo.insert(
          OAuth.App.register_changeset(%OAuth.App{}, %{
            client_name: "client",
            scopes: ["read"],
            redirect_uris: "url"
          })
        )

      user = insert(:user)

      {:ok, auth} = OAuth.Authorization.create_authorization(app, user)

      {:ok, token} = OAuth.Token.exchange_token(app, auth)

      %{app: app, user: user, token: token}
    end

    test "accepts valid tokens", state do
      assert {:ok, _} = start_socket("?stream=user&access_token=#{state.token.token}")
    end

    test "accepts the 'user' stream", %{token: token} = _state do
      assert {:ok, _} = start_socket("?stream=user&access_token=#{token.token}")

      capture_log(fn ->
        assert {:error, %WebSockex.RequestError{code: 401}} = start_socket("?stream=user")
        Process.sleep(30)
      end)
    end

    test "accepts the 'user:notification' stream", %{token: token} = _state do
      assert {:ok, _} = start_socket("?stream=user:notification&access_token=#{token.token}")

      capture_log(fn ->
        assert {:error, %WebSockex.RequestError{code: 401}} =
                 start_socket("?stream=user:notification")

        Process.sleep(30)
      end)
    end

    test "accepts valid token on Sec-WebSocket-Protocol header", %{token: token} do
      assert {:ok, _} = start_socket("?stream=user", [{"Sec-WebSocket-Protocol", token.token}])

      capture_log(fn ->
        assert {:error, %WebSockex.RequestError{code: 401}} =
                 start_socket("?stream=user", [{"Sec-WebSocket-Protocol", "I am a friend"}])

        Process.sleep(30)
      end)
    end

    test "echoes the Sec-WebSocket-Protocol token in the handshake", %{token: token} do
      assert {:ok, %{status: 101, headers: headers}} =
               raw_websocket_handshake("?stream=user", [
                 {"sec-websocket-protocol", token.token}
               ])

      assert {"sec-websocket-protocol", token.token} in headers
    end

    test "echoes the selected Sec-WebSocket-Protocol token", %{token: token} do
      assert {:ok, %{status: 101, headers: headers}} =
               raw_websocket_handshake("?stream=user", [
                 {"sec-websocket-protocol", "#{token.token}, phoenix"}
               ])

      assert {"sec-websocket-protocol", token.token} in headers
    end

    test "does not echo an invalid Sec-WebSocket-Protocol token", %{token: token} do
      assert {:ok, %{status: 401, headers: headers}} =
               raw_websocket_handshake("?stream=user", [
                 {"sec-websocket-protocol", "invalid"}
               ])

      refute {"sec-websocket-protocol", token.token} in headers
      refute List.keymember?(headers, "sec-websocket-protocol", 0)
    end

    test "prefers sec-websocket-protocol token over query access_token", %{
      token: token,
      user: user
    } do
      assert {:ok, state} =
               Pleroma.Web.MastodonAPI.WebsocketHandler.connect(%{
                 params: %{"stream" => "user", "access_token" => "invalid"},
                 connect_info: %{
                   sec_websocket_headers: [
                     {"sec-websocket-version", "13"},
                     {"sec-websocket-protocol", token.token}
                   ]
                 }
               })

      assert state.user.id == user.id
      assert state.oauth_token.id == token.id
      assert state.topics != []
    end

    test "accepts valid token on client-sent event", %{token: token} do
      assert {:ok, pid} = start_socket()

      WebsocketClient.send_text(
        pid,
        %{type: "pleroma:authenticate", token: token.token} |> Jason.encode!()
      )

      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "pleroma:authenticate", "result" => "success"}
              }} = decode_json(raw_json)

      WebsocketClient.send_text(pid, %{type: "subscribe", stream: "user"} |> Jason.encode!())
      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "success"}
              }} = decode_json(raw_json)
    end

    test "rejects invalid token on client-sent event" do
      assert {:ok, pid} = start_socket()

      WebsocketClient.send_text(
        pid,
        %{type: "pleroma:authenticate", token: "Something else"} |> Jason.encode!()
      )

      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{
                  "type" => "pleroma:authenticate",
                  "result" => "error",
                  "error" => "unauthorized"
                }
              }} = decode_json(raw_json)
    end

    test "rejects new authenticate request if already logged-in", %{token: token} do
      assert {:ok, pid} = start_socket()

      WebsocketClient.send_text(
        pid,
        %{type: "pleroma:authenticate", token: token.token} |> Jason.encode!()
      )

      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "pleroma:authenticate", "result" => "success"}
              }} = decode_json(raw_json)

      WebsocketClient.send_text(
        pid,
        %{type: "pleroma:authenticate", token: "Something else"} |> Jason.encode!()
      )

      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{
                  "type" => "pleroma:authenticate",
                  "result" => "error",
                  "error" => "already_authenticated"
                }
              }} = decode_json(raw_json)
    end

    test "accepts the 'list' stream", %{token: token, user: user} do
      posting_user = insert(:user)

      {:ok, list} = Pleroma.List.create(%{title: "test"}, user)
      Pleroma.List.follow(list, posting_user)

      assert {:ok, _} = start_socket("?stream=list&access_token=#{token.token}&list=#{list.id}")

      assert {:ok, pid} = start_socket("?access_token=#{token.token}")

      WebsocketClient.send_text(
        pid,
        %{type: "subscribe", stream: "list", list: list.id} |> Jason.encode!()
      )

      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "success"}
              }} = decode_json(raw_json)

      WebsocketClient.send_text(
        pid,
        %{type: "subscribe", stream: "list", list: to_string(list.id)} |> Jason.encode!()
      )

      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "pleroma:respond",
                "payload" => %{"type" => "subscribe", "result" => "ignored"}
              }} = decode_json(raw_json)
    end

    test "disconnect when token is revoked", %{app: app, user: user, token: token} do
      assert {:ok, _} = start_socket("?stream=user:notification&access_token=#{token.token}")
      assert {:ok, _} = start_socket("?stream=user&access_token=#{token.token}")

      {:ok, auth} = OAuth.Authorization.create_authorization(app, user)

      {:ok, token2} = OAuth.Token.exchange_token(app, auth)
      assert {:ok, _} = start_socket("?stream=user&access_token=#{token2.token}")

      OAuth.Token.Strategy.Revoke.revoke(token)

      assert_receive {:close, _}
      assert_receive {:close, _}
      refute_receive {:close, _}
    end

    test "receives private statuses", %{user: reading_user, token: token} do
      user = insert(:user)
      CommonAPI.follow(user, reading_user)

      {:ok, _} = start_socket("?stream=user&access_token=#{token.token}")

      {:ok, activity} =
        CommonAPI.post(user, %{status: "nice echo chamber", visibility: "private"})

      assert_receive {:text, raw_json}, 1_000
      assert {:ok, json} = Jason.decode(raw_json)

      assert "update" == json["event"]
      assert json["payload"]
      assert {:ok, json} = Jason.decode(json["payload"])

      view_json =
        atom_key_to_string(
          StatusView.render("show.json",
            activity: activity,
            for: reading_user
          )
        )

      assert json == view_json
    end

    test "receives edits", %{user: reading_user, token: token} do
      user = insert(:user)
      CommonAPI.follow(user, reading_user)

      {:ok, _} = start_socket("?stream=user&access_token=#{token.token}")

      {:ok, activity} =
        CommonAPI.post(user, %{status: "nice echo chamber", visibility: "private"})

      assert_receive {:text, _raw_json}, 1_000

      {:ok, _} = CommonAPI.update(activity, user, %{status: "mew mew", visibility: "private"})

      assert_receive {:text, raw_json}, 1_000

      activity = Pleroma.Activity.normalize(activity)

      view_json =
        atom_key_to_string(
          StatusView.render("show.json",
            activity: activity,
            for: reading_user
          )
        )

      assert {:ok, %{"event" => "status.update", "payload" => ^view_json}} = decode_json(raw_json)
    end

    test "receives notifications", %{user: reading_user, token: token} do
      user = insert(:user)
      CommonAPI.follow(user, reading_user)

      {:ok, _} = start_socket("?stream=user:notification&access_token=#{token.token}")

      {:ok, %Pleroma.Activity{id: activity_id} = _activity} =
        CommonAPI.post(user, %{
          status: "nice echo chamber @#{reading_user.nickname}",
          visibility: "private"
        })

      assert_receive {:text, raw_json}, 1_000

      assert {:ok,
              %{
                "event" => "notification",
                "payload" => %{
                  "status" => %{
                    "id" => ^activity_id
                  }
                }
              }} = decode_json(raw_json)
    end
  end
end
