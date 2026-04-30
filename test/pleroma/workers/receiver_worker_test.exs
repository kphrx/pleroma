# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorkerTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Mock
  import Pleroma.Factory

  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.ActivityPub.UserView
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.ReceiverWorker

  defp mismatched_signature_headers do
    [
      {"host", "example.com"},
      {"date", "Thu, 25 Jul 2024 13:33:31 GMT"},
      {"digest", "SHA-256=fake-digest"},
      {"content-type", "application/activity+json"},
      {
        "signature",
        "keyId=\"https://example.com/users/alice#main-key\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest content-type\",signature=\"fake-signature\""
      }
    ]
  end

  defp expect_signature_from(%User{} = signer) do
    signer_json = UserView.render("user.json", %{user: signer}) |> Map.delete("featured")

    Tesla.Mock.mock(fn
      %{url: url} when url == signer.ap_id ->
        %Tesla.Env{
          status: 200,
          body: Jason.encode!(signer_json),
          headers: HttpRequestMock.activitypub_object_headers()
        }
    end)

    Mox.expect(Pleroma.StubbedHTTPSignaturesMock, :validate_conn, fn _conn -> true end)
  end

  defp assert_mismatched_signature_cancelled(params, signer) do
    expect_signature_from(signer)

    assert {:ok, oban_job} =
             Federator.incoming_ap_doc(%{
               method: "POST",
               req_headers: mismatched_signature_headers(),
               request_path: "/inbox",
               params: params,
               query_string: ""
             })

    assert {:cancel, :actor_signature_mismatch} = ReceiverWorker.perform(oban_job)
  end

  test "it does not retry MRF reject" do
    params = insert(:note).data

    with_mock Pleroma.Web.ActivityPub.Transmogrifier,
      handle_incoming: fn _ -> {:reject, "MRF"} end do
      assert {:cancel, {:reject, "MRF"}} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it does not retry ObjectValidator reject" do
    params =
      insert(:note_activity).data
      |> Map.put("id", Pleroma.Web.ActivityPub.Utils.generate_activity_id())
      |> Map.put("object", %{
        "type" => "Note",
        "id" => Pleroma.Web.ActivityPub.Utils.generate_object_id()
      })

    with_mock Pleroma.Web.ActivityPub.ObjectValidator, [:passthrough],
      validate: fn _, _ -> {:error, %Ecto.Changeset{}} end do
      assert {:cancel, {:error, %Ecto.Changeset{}}} =
               ReceiverWorker.perform(%Oban.Job{
                 args: %{"op" => "incoming_ap_doc", "params" => params}
               })
    end
  end

  test "it does not retry duplicates" do
    params = insert(:note_activity).data

    assert {:cancel, :already_present} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{"op" => "incoming_ap_doc", "params" => params}
             })
  end

  describe "cancels on a failed user fetch" do
    setup do
      Tesla.Mock.mock(fn
        %{url: "https://springfield.social/users/bart"} ->
          %Tesla.Env{
            status: 403,
            body: ""
          }

        %{url: "https://springfield.social/users/troymcclure"} ->
          %Tesla.Env{
            status: 404,
            body: ""
          }

        %{url: "https://springfield.social/users/hankscorpio"} ->
          %Tesla.Env{
            status: 410,
            body: ""
          }
      end)
    end

    test "when request returns a 403" do
      params =
        insert(:note_activity).data
        |> Map.put("actor", "https://springfield.social/users/bart")

      {:ok, oban_job} =
        Federator.incoming_ap_doc(%{
          method: "POST",
          req_headers: [],
          request_path: "/inbox",
          params: params,
          query_string: ""
        })

      assert {:cancel, {:error, :forbidden}} = ReceiverWorker.perform(oban_job)
    end

    test "when request returns a 404" do
      params =
        insert(:note_activity).data
        |> Map.put("actor", "https://springfield.social/users/troymcclure")

      {:ok, oban_job} =
        Federator.incoming_ap_doc(%{
          method: "POST",
          req_headers: [],
          request_path: "/inbox",
          params: params,
          query_string: ""
        })

      assert {:cancel, {:error, :not_found}} = ReceiverWorker.perform(oban_job)
    end

    test "when request returns a 410" do
      params =
        insert(:note_activity).data
        |> Map.put("actor", "https://springfield.social/users/hankscorpio")

      {:ok, oban_job} =
        Federator.incoming_ap_doc(%{
          method: "POST",
          req_headers: [],
          request_path: "/inbox",
          params: params,
          query_string: ""
        })

      assert {:cancel, {:error, :not_found}} = ReceiverWorker.perform(oban_job)
    end

    test "when user account is disabled" do
      user = insert(:user)

      fake_activity = URI.parse(user.ap_id) |> Map.put(:path, "/fake-activity") |> to_string

      params =
        insert(:note_activity, user: user).data
        |> Map.put("id", fake_activity)

      {:ok, %User{}} = User.set_activation(user, false)

      {:ok, oban_job} =
        Federator.incoming_ap_doc(%{
          method: "POST",
          req_headers: [],
          request_path: "/inbox",
          params: params,
          query_string: ""
        })

      assert {:cancel, {:user_active, false}} = ReceiverWorker.perform(oban_job)
    end
  end

  test "it can validate the signature" do
    Tesla.Mock.mock(fn
      %{url: "https://phpc.social/users/denniskoch"} ->
        %Tesla.Env{
          status: 200,
          body: File.read!("test/fixtures/denniskoch.json"),
          headers: [{"content-type", "application/activity+json"}]
        }

      %{url: "https://phpc.social/users/denniskoch/collections/featured"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "application/activity+json"}],
          body:
            File.read!("test/fixtures/users_mock/masto_featured.json")
            |> String.replace("{{domain}}", "phpc.social")
            |> String.replace("{{nickname}}", "denniskoch")
        }
    end)

    params =
      File.read!("test/fixtures/receiver_worker_signature_activity.json") |> Jason.decode!()

    req_headers = [
      ["accept-encoding", "gzip"],
      ["content-length", "5184"],
      ["content-type", "application/activity+json"],
      ["date", "Thu, 25 Jul 2024 13:33:31 GMT"],
      ["digest", "SHA-256=ouge/6HP2/QryG6F3JNtZ6vzs/hSwMk67xdxe87eH7A="],
      ["host", "bikeshed.party"],
      [
        "signature",
        "keyId=\"https://mastodon.social/users/bastianallgeier#main-key\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest content-type\",signature=\"ymE3vn5Iw50N6ukSp8oIuXJB5SBjGAGjBasdTDvn+ahZIzq2SIJfmVCsIIzyqIROnhWyQoTbavTclVojEqdaeOx+Ejz2wBnRBmhz5oemJLk4RnnCH0lwMWyzeY98YAvxi9Rq57Gojuv/1lBqyGa+rDzynyJpAMyFk17XIZpjMKuTNMCbjMDy76ILHqArykAIL/v1zxkgwxY/+ELzxqMpNqtZ+kQ29znNMUBB3eVZ/mNAHAz6o33Y9VKxM2jw+08vtuIZOusXyiHbRiaj2g5HtN2WBUw1MzzfRfHF2/yy7rcipobeoyk5RvP5SyHV3WrIeZ3iyoNfmv33y8fxllF0EA==\""
      ],
      [
        "user-agent",
        "http.rb/5.2.0 (Mastodon/4.3.0-nightly.2024-07-25; +https://mastodon.social/)"
      ]
    ]

    {:ok, oban_job} =
      Federator.incoming_ap_doc(%{
        method: "POST",
        req_headers: req_headers,
        request_path: "/inbox",
        params: params,
        query_string: ""
      })

    assert {:ok, %Pleroma.Activity{}} = ReceiverWorker.perform(oban_job)
  end

  test "cancels due to origin containment" do
    params =
      insert(:note_activity).data
      |> Map.put("id", "https://notorigindomain.com/activity")

    {:ok, oban_job} =
      Federator.incoming_ap_doc(%{
        method: "POST",
        req_headers: [],
        request_path: "/inbox",
        params: params,
        query_string: ""
      })

    assert {:cancel, :origin_containment_failed} = ReceiverWorker.perform(oban_job)
  end

  test "canceled due to deleted object" do
    params =
      insert(:announce_activity).data
      |> Map.put("object", "http://localhost:4001/deleted")

    Tesla.Mock.mock(fn
      %{url: "http://localhost:4001/deleted"} ->
        %Tesla.Env{
          status: 404,
          body: ""
        }
    end)

    {:ok, oban_job} =
      Federator.incoming_ap_doc(%{
        method: "POST",
        req_headers: [],
        request_path: "/inbox",
        params: params,
        query_string: ""
      })

    assert {:cancel, _} = ReceiverWorker.perform(oban_job)
  end

  describe "Server reachability:" do
    setup do
      user = insert(:user)
      remote_user = insert(:user, local: false, ap_id: "https://example.com/users/remote")
      {:ok, _, _} = Pleroma.User.follow(user, remote_user)
      {:ok, activity} = CommonAPI.post(remote_user, %{status: "Test post"})

      %{
        user: user,
        remote_user: remote_user,
        activity: activity
      }
    end

    test "schedules ReachabilityWorker if host is unreachable", %{activity: activity} do
      with_mocks [
        {Pleroma.Web.ActivityPub.Transmogrifier, [],
         [handle_incoming: fn _ -> {:ok, activity} end]},
        {Pleroma.Instances, [], [reachable?: fn _ -> false end]},
        {Pleroma.Web.Federator, [], [perform: fn :incoming_ap_doc, _params -> {:ok, nil} end]}
      ] do
        job = %Oban.Job{
          args: %{
            "op" => "incoming_ap_doc",
            "params" => activity.data
          }
        }

        Pleroma.Workers.ReceiverWorker.perform(job)

        assert_enqueued(
          worker: Pleroma.Workers.ReachabilityWorker,
          args: %{"domain" => "example.com"}
        )
      end
    end

    test "does not schedule ReachabilityWorker if host is reachable", %{activity: activity} do
      with_mocks [
        {Pleroma.Web.ActivityPub.Transmogrifier, [],
         [handle_incoming: fn _ -> {:ok, activity} end]},
        {Pleroma.Instances, [], [reachable?: fn _ -> true end]},
        {Pleroma.Web.Federator, [], [perform: fn :incoming_ap_doc, _params -> {:ok, nil} end]}
      ] do
        job = %Oban.Job{
          args: %{
            "op" => "incoming_ap_doc",
            "params" => activity.data
          }
        }

        Pleroma.Workers.ReceiverWorker.perform(job)

        refute_enqueued(worker: Pleroma.Workers.ReachabilityWorker)
      end
    end
  end

  test "cancels when signature actor does not match payload actor" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")

    note = insert(:note, user: bob, object_local: false)

    update = %{
      "type" => "Update",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/malicious-update",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data
    }

    req_headers = [
      ["host", "example.com"],
      ["date", "Thu, 25 Jul 2024 13:33:31 GMT"],
      ["digest", "SHA-256=fake-digest"],
      ["content-type", "application/activity+json"],
      [
        "signature",
        "keyId=\"https://example.com/users/alice#main-key\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest content-type\",signature=\"fake-signature\""
      ]
    ]

    oban_job = %Oban.Job{
      args: %{
        "op" => "incoming_ap_doc",
        "method" => "POST",
        "params" => update,
        "req_headers" => req_headers,
        "request_path" => "/inbox",
        "query_string" => ""
      }
    }

    expect_signature_from(alice)

    assert {:cancel, :actor_signature_mismatch} = ReceiverWorker.perform(oban_job)
  end

  test "Federator preserves request metadata needed for ReceiverWorker signature checks" do
    params = insert(:note_activity).data

    req_headers = [
      {"host", "example.com"},
      {"signature", "keyId=\"https://example.com/users/alice#main-key\""}
    ]

    assert {:ok, oban_job} =
             Federator.incoming_ap_doc(%{
               method: "POST",
               req_headers: req_headers,
               request_path: "/inbox",
               params: params,
               query_string: "foo=bar"
             })

    assert %{
             "method" => "POST",
             "req_headers" => ^req_headers,
             "request_path" => "/inbox",
             "params" => ^params,
             "query_string" => "foo=bar"
           } = oban_job.args
  end

  test "cancels signature actor mismatch through Federator-created jobs" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")

    note = insert(:note, user: bob, object_local: false)

    update = %{
      "type" => "Update",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/federator-malicious-update",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data
    }

    assert_mismatched_signature_cancelled(update, alice)
  end

  test "cancels signature actor mismatch before processing a forged Create" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")

    create = %{
      "type" => "Create",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/forged-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => "https://example.com/objects/forged-note",
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

  test "cancels signature actor mismatch before actually creating a forged post" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")

    object_id = "https://example.com/objects/actually-forged-note"

    create = %{
      "type" => "Create",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/actually-forged-create",
      "context" => "https://example.com/contexts/actually-forged-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => object_id,
        "actor" => bob.ap_id,
        "attributedTo" => bob.ap_id,
        "context" => "https://example.com/contexts/actually-forged-create",
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    expect_signature_from(alice)

    assert {:ok, oban_job} =
             Federator.incoming_ap_doc(%{
               method: "POST",
               req_headers: mismatched_signature_headers(),
               request_path: "/inbox",
               params: create,
               query_string: ""
             })

    assert {:cancel, :actor_signature_mismatch} = ReceiverWorker.perform(oban_job)
    refute Pleroma.Object.get_by_ap_id(object_id)
  end

  test "cancels signature actor mismatch before processing a forged Like" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")
    note = insert(:note)

    like = %{
      "type" => "Like",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/forged-like",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data["id"]
    }

    assert_mismatched_signature_cancelled(like, alice)
  end

  test "cancels signature actor mismatch before actually creating a forged Like" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")
    note = insert(:note)

    like = %{
      "type" => "Like",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/actually-forged-like",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data["id"]
    }

    expect_signature_from(alice)

    assert {:ok, oban_job} =
             Federator.incoming_ap_doc(%{
               method: "POST",
               req_headers: mismatched_signature_headers(),
               request_path: "/inbox",
               params: like,
               query_string: ""
             })

    assert {:cancel, :actor_signature_mismatch} = ReceiverWorker.perform(oban_job)
    refute Pleroma.Activity.get_by_ap_id(like["id"])
  end

  test "cancels signature actor mismatch before processing a forged Announce" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")
    note = insert(:note)

    announce = %{
      "type" => "Announce",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/forged-announce",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => note.data["id"]
    }

    assert_mismatched_signature_cancelled(announce, alice)
  end

  test "cancels signature actor mismatch before processing a forged Follow" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")
    followed = insert(:user)

    follow = %{
      "type" => "Follow",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/forged-follow",
      "to" => [followed.ap_id],
      "cc" => [],
      "object" => followed.ap_id
    }

    assert_mismatched_signature_cancelled(follow, alice)
  end

  test "cancels signature actor mismatch before processing a forged Undo" do
    alice = insert(:user, local: false, ap_id: "https://example.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://example.com/users/bob")

    undo = %{
      "type" => "Undo",
      "actor" => bob.ap_id,
      "id" => "https://example.com/activities/forged-undo",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => "https://example.com/activities/existing-bob-activity"
    }

    assert_mismatched_signature_cancelled(undo, alice)
  end
end
