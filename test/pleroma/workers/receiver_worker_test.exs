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
  alias Pleroma.Workers.ReceiverWorker

  defp signature_headers_for(%User{} = signer) do
    [
      {"host", "local.test"},
      {"date", "Thu, 25 Jul 2024 13:33:31 GMT"},
      {"digest", "SHA-256=fake-digest"},
      {"content-type", "application/activity+json"},
      {
        "signature",
        "keyId=\"#{signer.ap_id}#main-key\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest content-type\",signature=\"fake-signature\""
      }
    ]
  end

  defp perform_incoming(params) do
    ReceiverWorker.perform(%Oban.Job{
      args: %{"op" => "incoming_ap_doc", "params" => params}
    })
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

      assert {:cancel, {:error, :forbidden}} = perform_incoming(params)
    end

    test "when request returns a 404" do
      params =
        insert(:note_activity).data
        |> Map.put("actor", "https://springfield.social/users/troymcclure")

      assert {:cancel, {:error, :not_found}} = perform_incoming(params)
    end

    test "when request returns a 410" do
      params =
        insert(:note_activity).data
        |> Map.put("actor", "https://springfield.social/users/hankscorpio")

      assert {:cancel, {:error, :not_found}} = perform_incoming(params)
    end

    test "when user account is disabled" do
      user = insert(:user)

      fake_activity = URI.parse(user.ap_id) |> Map.put(:path, "/fake-activity") |> to_string

      params =
        insert(:note_activity, user: user).data
        |> Map.put("id", fake_activity)

      {:ok, %User{}} = User.set_activation(user, false)

      assert {:cancel, {:user_active, false}} = perform_incoming(params)
    end
  end

  test "cancels due to origin containment" do
    params =
      insert(:note_activity).data
      |> Map.put("id", "https://notorigindomain.com/activity")

    assert {:cancel, :origin_containment_failed} = perform_incoming(params)
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

    assert {:cancel, _} = perform_incoming(params)
  end

  test "delegates legacy failed-signature metadata jobs instead of processing them as trusted" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")
    object_id = "https://two.com/objects/legacy-forged-note"

    create = %{
      "type" => "Create",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/legacy-forged-create",
      "context" => "https://two.com/contexts/legacy-forged-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => object_id,
        "actor" => bob.ap_id,
        "attributedTo" => bob.ap_id,
        "context" => "https://two.com/contexts/legacy-forged-create",
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    assert {:cancel, :actor_signature_mismatch} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{
                 "op" => "incoming_ap_doc",
                 "method" => "POST",
                 "params" => create,
                 "req_headers" => signature_headers_for(alice),
                 "request_path" => "/inbox",
                 "query_string" => ""
               }
             })

    refute Pleroma.Activity.get_by_ap_id(create["id"])
    refute Pleroma.Object.get_by_ap_id(object_id)
  end

  test "fails closed for the old persisted failed-signature job shape" do
    alice = insert(:user, local: false, ap_id: "https://one.com/users/alice")
    bob = insert(:user, local: false, ap_id: "https://two.com/users/bob")
    object_id = "https://two.com/objects/old-shape-forged-note"

    create = %{
      "type" => "Create",
      "actor" => bob.ap_id,
      "id" => "https://two.com/activities/old-shape-forged-create",
      "context" => "https://two.com/contexts/old-shape-forged-create",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "object" => %{
        "type" => "Note",
        "id" => object_id,
        "actor" => bob.ap_id,
        "attributedTo" => bob.ap_id,
        "context" => "https://two.com/contexts/old-shape-forged-create",
        "content" => "forged post",
        "published" => "2024-07-25T13:33:31Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    assert {:cancel, :missing_signature_retry_metadata} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{
                 "op" => "incoming_ap_doc",
                 "params" => create,
                 "req_headers" => signature_headers_for(alice),
                 "timeout" => 20_000
               }
             })

    refute Pleroma.Activity.get_by_ap_id(create["id"])
    refute Pleroma.Object.get_by_ap_id(object_id)
  end

  test "fails closed for malformed legacy metadata jobs without params" do
    assert {:cancel, :missing_signature_retry_metadata} =
             ReceiverWorker.perform(%Oban.Job{
               args: %{
                 "op" => "incoming_ap_doc",
                 "req_headers" => [],
                 "timeout" => 20_000
               }
             })
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
end
