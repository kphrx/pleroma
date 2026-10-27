# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.HTTPSignaturePlugPolicyTest do
  # Not async: changes global config and uses global HTTP mocks.
  use Pleroma.Web.ConnCase

  alias Pleroma.Keys
  alias Pleroma.Object.Fetcher
  alias Pleroma.Repo
  alias Pleroma.StubbedHTTPSignaturesMock, as: HTTPSignaturesMock
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.InternalFetchActor
  alias Pleroma.Web.ActivityPub.Publisher
  alias Pleroma.Web.Plugs.DigestPlug
  alias Pleroma.Web.Plugs.HTTPSignaturePlug

  import ExUnit.CaptureLog
  import Mox
  import Phoenix.Controller, only: [put_format: 2]
  import Pleroma.Factory
  import Plug.Conn

  defp incoming_conn(method, url, headers, body \\ "") do
    %URI{host: host, path: path} = URI.parse(url)

    headers = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)

    Plug.Test.conn(method, path, body)
    |> Map.put(:req_headers, [{"host", host} | headers])
    |> put_format("activity+json")
  end

  # Local users have no public_key column set; publish it like a remote copy would.
  defp store_public_key(%User{} = user) do
    {:ok, _, public_key} = Keys.keys_from_pem(user.keys)
    entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)

    user
    |> Ecto.Changeset.change(public_key: :public_key.pem_encode([entry]))
    |> Repo.update!()
    |> User.set_cache()
  end

  defp capture_request(method) do
    test_pid = self()

    Tesla.Mock.mock_global(fn %{method: ^method, headers: headers, body: body} = env ->
      send(test_pid, {:request, headers, body})
      %{env | status: 200, body: ""}
    end)
  end

  test "accepts deliveries signed by Pleroma's publisher" do
    stub_with(Pleroma.Web.ActivityPub.TransmogrifierMock, Pleroma.Web.ActivityPub.Transmogrifier)
    capture_request(:post)

    activity = insert(:note_activity)
    store_public_key(User.get_by_ap_id(activity.data["actor"]))
    inbox = "https://remote.example/inbox"

    {:ok, _} =
      %{inbox: inbox, activity_id: activity.id}
      |> Publisher.prepare_one()
      |> Publisher.publish_one()

    assert_received {:request, headers, body}

    {:ok, _, conn} =
      incoming_conn(:post, inbox, [{"content-length", "#{byte_size(body)}"} | headers], body)
      |> DigestPlug.read_body([])

    conn = HTTPSignaturePlug.call(conn, %{})

    assert conn.assigns.valid_signature == true
    refute conn.halted
  end

  test "accepts object fetches signed by Pleroma's fetcher" do
    clear_config([:activitypub, :sign_object_fetches], true)
    capture_request(:get)
    store_public_key(InternalFetchActor.get_actor())

    url = "https://remote.example/objects/1"
    Fetcher.fetch_and_contain_remote_object_from_id(url)

    assert_received {:request, headers, _body}

    conn =
      incoming_conn(:get, url, headers)
      |> HTTPSignaturePlug.call(%{})

    assert conn.assigns.valid_signature == true
  end

  test "only logs policy violations when the policy is set to :log" do
    clear_config([:activitypub, :signature_policy], :log)

    HTTPSignaturesMock
    |> expect(:validate_conn, fn _ -> true end)

    log =
      capture_log(fn ->
        conn =
          incoming_conn(:post, "https://pleroma.example/inbox", [
            {"date", Pleroma.Signature.signed_date()},
            {"signature",
             "keyId=\"https://remote.example/users/a#main-key\",headers=\"(request-target) host date\",signature=\"fake\""}
          ])
          |> HTTPSignaturePlug.call(%{})

        assert conn.assigns.valid_signature == true
        refute conn.halted
      end)

    assert log =~ "digest_not_signed"
  end
end
