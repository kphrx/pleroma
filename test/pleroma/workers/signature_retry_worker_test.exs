# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.SignatureRetryWorkerTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import ExUnit.CaptureLog
  import Pleroma.Factory

  @moduletag capture_log: true

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Signature
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.UserView
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.SignatureRetryWorker

  defp signature_headers_for(%User{} = signer) do
    [
      {"host", "#{URI.parse(Endpoint.url()).host}"},
      {"date", "Thu, 25 Jul 2024 13:33:31 GMT"},
      {"digest", "SHA-256=fake-digest"},
      {"content-type", "application/activity+json"},
      {
        "signature",
        "keyId=\"#{signer.ap_id}#main-key\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest content-type\",signature=\"fake-signature\""
      }
    ]
  end

  defp stub_actor_fetch(%User{} = signer) do
    signer_json = UserView.render("user.json", %{user: signer}) |> Map.delete("featured")

    Tesla.Mock.mock(fn
      %{url: url} when url == signer.ap_id ->
        %Tesla.Env{
          status: 200,
          body: Jason.encode!(signer_json),
          headers: HttpRequestMock.activitypub_object_headers()
        }
    end)
  end

  defp expect_signature_from(%User{} = signer) do
    stub_actor_fetch(signer)
    Mox.expect(Pleroma.StubbedHTTPSignaturesMock, :validate_conn, fn _conn -> true end)
  end

  defp enqueue_failed_signature(params, signer) do
    Federator.incoming_failed_signature_ap_doc(%{
      method: "POST",
      req_headers: signature_headers_for(signer),
      request_path: "/inbox",
      params: params,
      query_string: ""
    })
  end

  defp failed_signature_job(params, req_headers, opts \\ []) do
    %Oban.Job{
      args: %{
        "op" => "incoming_failed_signature_ap_doc",
        "method" => Keyword.get(opts, :method, "POST"),
        "req_headers" => req_headers,
        "request_path" => Keyword.get(opts, :request_path, "/inbox"),
        "params" => params,
        "query_string" => Keyword.get(opts, :query_string, "")
      }
    }
  end

  defp assert_mismatched_signature_cancelled(params, signer) do
    assert {:ok, oban_job} = enqueue_failed_signature(params, signer)

    capture_log([level: :warning], fn ->
      assert {:cancel, :actor_signature_mismatch} = SignatureRetryWorker.perform(oban_job)
    end)
  end

  test "Federator preserves request metadata for failed-signature retry jobs" do
    params = insert(:note_activity).data

    req_headers = [
      {"host", "local.test"},
      {"signature", "keyId=\"https://one.com/users/alice#main-key\""}
    ]

    assert {:ok, oban_job} =
             Federator.incoming_failed_signature_ap_doc(%{
               method: "POST",
               req_headers: req_headers,
               request_path: "/inbox",
               params: params,
               query_string: "foo=bar"
             })

    assert oban_job.worker == "Pleroma.Workers.SignatureRetryWorker"

    assert %{
             "op" => "incoming_failed_signature_ap_doc",
             "method" => "POST",
             "req_headers" => ^req_headers,
             "request_path" => "/inbox",
             "params" => ^params,
             "query_string" => "foo=bar"
           } = oban_job.args
  end

  test "cancels retry jobs without request metadata" do
    params = insert(:note_activity).data

    log =
      capture_log([level: :warning], fn ->
        assert {:cancel, :missing_signature_retry_metadata} =
                 SignatureRetryWorker.perform(%Oban.Job{
                   args: %{"op" => "incoming_failed_signature_ap_doc", "params" => params}
                 })
      end)

    assert log =~ "Failed-signature inbox retry rejected"
    assert log =~ "reason=:missing_signature_retry_metadata"
    assert log =~ "payload_actor=#{inspect(params["actor"])}"
    assert log =~ "activity_id=#{inspect(params["id"])}"
    assert log =~ "type=#{inspect(params["type"])}"
    assert log =~ "request_path=nil"
  end

  test "cancels retry jobs with malformed serialized request headers" do
    params = insert(:note_activity).data

    log =
      capture_log([level: :warning], fn ->
        assert {:cancel, :invalid_signature_retry_metadata} =
                 SignatureRetryWorker.perform(failed_signature_job(params, [["signature"]]))
      end)

    assert log =~ "Failed-signature inbox retry rejected"
    assert log =~ "reason=:invalid_signature_retry_metadata"
    assert log =~ "signature_actor=nil"
    assert log =~ "request_path=\"/inbox\""
  end

  test "cancels retry jobs without a signature header" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    params = insert(:note_activity, user: alice).data

    log =
      capture_log([level: :warning], fn ->
        assert {:cancel, :invalid_signature} =
                 SignatureRetryWorker.perform(
                   failed_signature_job(params, [{"host", "local.test"}])
                 )
      end)

    assert log =~ "Failed-signature inbox retry rejected"
    assert log =~ "reason=:invalid_signature"
    assert log =~ "payload_actor=#{inspect(params["actor"])}"
    assert log =~ "signature_actor=nil"
    assert log =~ "request_path=\"/inbox\""
  end

  test "cancels missing signature before fetching an unavailable payload actor" do
    params =
      insert(:note_activity).data
      |> Map.put("actor", "https://unavailable.example/users/bob")

    assert {:cancel, :invalid_signature} =
             SignatureRetryWorker.perform(failed_signature_job(params, [{"host", "local.test"}]))
  end

  test "cancels signer mismatch before fetching an unavailable payload actor" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")

    params =
      insert(:note_activity).data
      |> Map.put("actor", "https://unavailable.example/users/bob")

    assert {:cancel, :actor_signature_mismatch} =
             SignatureRetryWorker.perform(
               failed_signature_job(params, signature_headers_for(alice))
             )
  end

  test "cancels retry jobs with a signature header without keyId" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    params = insert(:note_activity, user: alice).data

    req_headers = [{"signature", "algorithm=\"rsa-sha256\",signature=\"fake-signature\""}]

    assert {:cancel, :invalid_signature} =
             SignatureRetryWorker.perform(failed_signature_job(params, req_headers))
  end

  test "cancels retry jobs with an unparsable signature keyId" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    params = insert(:note_activity, user: alice).data
    req_headers = [{"signature", "keyId=\"not an activitypub id\",signature=\"fake-signature\""}]

    assert {:cancel, :invalid_signature} =
             SignatureRetryWorker.perform(failed_signature_job(params, req_headers))
  end

  test "cancels when the refetched key still cannot validate the signature" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")

    create = %{
      "type" => "Create",
      "actor" => alice.ap_id,
      "id" => "https://one.com/activities/invalid-signature-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => "https://one.com/objects/invalid-signature-note",
        "actor" => alice.ap_id,
        "attributedTo" => alice.ap_id,
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    stub_actor_fetch(alice)

    assert {:ok, oban_job} = enqueue_failed_signature(create, alice)

    log =
      capture_log([level: :warning], fn ->
        assert {:cancel, :invalid_signature} = SignatureRetryWorker.perform(oban_job)
      end)

    assert log =~ "Failed-signature inbox retry rejected"
    assert log =~ "reason=:invalid_signature"
    assert log =~ "payload_actor=\"https://one.com/users/alice\""
    assert log =~ "signature_actor=\"https://one.com/users/alice\""
    assert log =~ "activity_id=\"https://one.com/activities/invalid-signature-create\""
    assert log =~ "type=\"Create\""
    assert log =~ "request_path=\"/inbox\""

    refute Activity.get_by_ap_id(create["id"])
  end

  test "cancels when the Host header does not match Endpoint" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")

    create = %{
      "type" => "Create",
      "actor" => alice.ap_id,
      "id" => "https://one.com/activities/invalid-signature-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => "https://one.com/objects/invalid-signature-note",
        "actor" => alice.ap_id,
        "attributedTo" => alice.ap_id,
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    expect_signature_from(alice)

    headers =
      [
        {"host", "invalid.example.com"},
        {"date", "Thu, 25 Jul 2024 13:33:31 GMT"},
        {"digest", "SHA-256=fake-digest"},
        {"content-type", "application/activity+json"},
        {
          "signature",
          "keyId=\"#{alice.ap_id}#main-key\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest content-type\",signature=\"fake-signature\""
        }
      ]

    assert {:ok, oban_job} = Federator.incoming_failed_signature_ap_doc(%{
        method: "POST",
        req_headers: headers,
        request_path: "/inbox",
        params: create,
        query_string: ""
      })

    log =
      capture_log([level: :warning], fn ->
        assert {:cancel, :host_header_mismatch} = SignatureRetryWorker.perform(oban_job)
      end)

    assert log =~ "Failed-signature inbox retry rejected"
    assert log =~ "reason=:host_header_mismatch"
    assert log =~ "payload_actor=\"https://one.com/users/alice\""
    assert log =~ "signature_actor=\"https://one.com/users/alice\""
    assert log =~ "activity_id=\"https://one.com/activities/invalid-signature-create\""
    assert log =~ "type=\"Create\""
    assert log =~ "request_path=\"/inbox\""

    refute Activity.get_by_ap_id(create["id"])
  end

  test "processes the activity after refetching a valid matching signature" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")

    create = %{
      "type" => "Create",
      "actor" => alice.ap_id,
      "id" => "https://one.com/activities/valid-signature-create",
      "context" => "https://one.com/contexts/valid-signature-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => "https://one.com/objects/valid-signature-note",
        "actor" => alice.ap_id,
        "attributedTo" => alice.ap_id,
        "context" => "https://one.com/contexts/valid-signature-create",
        "content" => "valid post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    expect_signature_from(alice)

    assert {:ok, oban_job} = enqueue_failed_signature(create, alice)
    assert {:ok, %Activity{}} = SignatureRetryWorker.perform(oban_job)
    assert Activity.get_by_ap_id(create["id"])
  end

  test "processes the activity when a real signature validates with a query string" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")

    create = %{
      "type" => "Create",
      "actor" => alice.ap_id,
      "id" => "https://one.com/activities/valid-query-signature-create",
      "context" => "https://one.com/contexts/valid-query-signature-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => "https://one.com/objects/valid-query-signature-note",
        "actor" => alice.ap_id,
        "attributedTo" => alice.ap_id,
        "context" => "https://one.com/contexts/valid-query-signature-create",
        "content" => "valid signed post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    stub_actor_fetch(alice)

    date = "Thu, 25 Jul 2024 13:33:31 GMT"
    digest = "SHA-256=fake-digest"

    signature =
      Signature.sign(alice, %{
        "(request-target)" => "post /inbox?foo=bar",
        "content-type" => "application/activity+json",
        date: date,
        digest: digest,
        host: "#{URI.parse(Endpoint.url()).host}"
      })

    req_headers = [
      ["host", "#{URI.parse(Endpoint.url()).host}"],
      ["date", date],
      ["digest", digest],
      ["content-type", "application/activity+json"],
      ["signature", signature]
    ]

    assert {:ok, %Activity{}} =
             SignatureRetryWorker.perform(
               failed_signature_job(create, req_headers, query_string: "foo=bar")
             )

    assert Activity.get_by_ap_id(create["id"])
  end

  test "cancels when signature actor does not match payload actor" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")

    note =
      insert(:note,
        user: bob,
        object_local: false,
        data: %{"id" => "https://two.com/objects/malicious-update-note"}
      )

    update = %{
      "type" => "Update",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/malicious-update",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data
    }

    assert_mismatched_signature_cancelled(update, alice)
  end

  test "cancels signature actor mismatch through Federator-created jobs" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")

    note =
      insert(:note,
        user: bob,
        object_local: false,
        data: %{"id" => "https://two.com/objects/federator-malicious-note"}
      )

    update = %{
      "type" => "Update",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/federator-malicious-update",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data
    }

    assert_mismatched_signature_cancelled(update, alice)
  end

  test "cancels signature actor mismatch before processing a forged Create" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")

    create = %{
      "type" => "Create",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/forged-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => "https://two.com/objects/forged-note",
        "actor" => bob.ap_id,
        "attributedTo" => bob.ap_id,
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    assert_mismatched_signature_cancelled(create, alice)
  end

  test "cancels signature actor mismatch when payload actor is embedded" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")

    create = %{
      "type" => "Create",
      "actor" => %{"id" => bob.ap_id},
      "id" => "https://two.com/activities/embedded-actor-forged-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => "https://two.com/objects/embedded-actor-forged-note",
        "actor" => bob.ap_id,
        "attributedTo" => bob.ap_id,
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    assert_mismatched_signature_cancelled(create, alice)
  end

  test "logs signature actor mismatch retry rejections" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")

    create = %{
      "type" => "Create",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/logged-forged-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => "https://two.com/objects/logged-forged-note",
        "actor" => bob.ap_id,
        "attributedTo" => bob.ap_id,
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    log = assert_mismatched_signature_cancelled(create, alice)

    assert log =~ "Failed-signature inbox retry rejected"
    assert log =~ "reason=:actor_signature_mismatch"
    assert log =~ "payload_actor=\"https://two.com/users/bob\""
    assert log =~ "signature_actor=\"https://one.com/users/alice\""
    assert log =~ "activity_id=\"https://two.com/activities/logged-forged-create\""
    assert log =~ "type=\"Create\""
    assert log =~ "request_path=\"/inbox\""
  end

  test "cancels signature actor mismatch before actually creating a forged post" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")

    object_id = "https://two.com/objects/actually-forged-note"

    create = %{
      "type" => "Create",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/actually-forged-create",
      "context" => "https://two.com/contexts/actually-forged-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => object_id,
        "actor" => bob.ap_id,
        "attributedTo" => bob.ap_id,
        "context" => "https://two.com/contexts/actually-forged-create",
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    assert_mismatched_signature_cancelled(create, alice)
    refute Object.get_by_ap_id(object_id)
  end

  test "cancels signature actor mismatch before processing a forged Like" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")
    note = insert(:note)

    like = %{
      "type" => "Like",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/forged-like",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data["id"]
    }

    assert_mismatched_signature_cancelled(like, alice)
  end

  test "cancels signature actor mismatch before actually creating a forged Like" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")
    note = insert(:note)

    like = %{
      "type" => "Like",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/actually-forged-like",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data["id"]
    }

    assert_mismatched_signature_cancelled(like, alice)
    refute Activity.get_by_ap_id(like["id"])
  end

  test "cancels signature actor mismatch before processing a forged Announce" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")
    note = insert(:note)

    announce = %{
      "type" => "Announce",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/forged-announce",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data["id"]
    }

    assert_mismatched_signature_cancelled(announce, alice)
  end

  test "cancels signature actor mismatch before processing a forged Follow" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")
    followed = insert(:user)

    follow = %{
      "type" => "Follow",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/forged-follow",
      "to" => [followed.ap_id],
      "cc" => [],
      "object" => followed.ap_id
    }

    assert_mismatched_signature_cancelled(follow, alice)
  end

  test "cancels signature actor mismatch before processing a forged Undo" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")

    undo = %{
      "type" => "Undo",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/forged-undo",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => "https://two.com/activities/existing-bob-activity"
    }

    assert_mismatched_signature_cancelled(undo, alice)
  end
end
