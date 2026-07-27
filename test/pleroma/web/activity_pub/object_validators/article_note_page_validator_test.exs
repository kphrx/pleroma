# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidatorTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Language.LanguageDetectorMock
  alias Pleroma.StaticStubbedConfigMock
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator
  alias Pleroma.Web.ActivityPub.Utils

  import Mox
  import Pleroma.Factory

  # Setup for all tests
  setup do
    # Stub the StaticStubbedConfigMock to return our mock for the provider
    StaticStubbedConfigMock
    |> stub(:get, fn
      [Pleroma.Language.LanguageDetector, :provider] -> LanguageDetectorMock
      _other -> nil
    end)

    # Stub the LanguageDetectorMock with default implementations
    LanguageDetectorMock
    |> stub(:missing_dependencies, fn -> [] end)
    |> stub(:configured?, fn -> true end)
    |> stub(:detect, fn _text -> nil end)

    :ok
  end

  describe "Notes" do
    setup do
      user = insert(:user)

      note = %{
        "id" => Utils.generate_activity_id(),
        "type" => "Note",
        "actor" => user.ap_id,
        "to" => [user.follower_address],
        "cc" => [],
        "content" => "Hellow this is content.",
        "context" => "xxx",
        "summary" => "a post"
      }

      %{user: user, note: note}
    end

    test "a basic note validates", %{note: note} do
      %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
    end

    test "a note from factory validates" do
      note = insert(:note)
      %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note.data)
    end
  end

  describe "Note with history" do
    setup do
      user = insert(:user)
      {:ok, activity} = Pleroma.Web.CommonAPI.post(user, %{status: "mew mew :dinosaur:"})
      {:ok, edit} = Pleroma.Web.CommonAPI.update(activity, user, %{status: "edited :blank:"})

      {:ok, %{"object" => external_rep}} =
        Pleroma.Web.ActivityPub.Transmogrifier.prepare_activity(edit.data)

      %{external_rep: external_rep}
    end

    test "edited note", %{external_rep: external_rep} do
      assert %{"formerRepresentations" => %{"orderedItems" => [%{"tag" => [_]}]}} = external_rep

      {:ok, validate_res, []} = ObjectValidator.validate(external_rep, [])

      assert %{"formerRepresentations" => %{"orderedItems" => [%{"emoji" => %{"dinosaur" => _}}]}} =
               validate_res
    end

    test "edited note, badly-formed formerRepresentations", %{external_rep: external_rep} do
      external_rep = Map.put(external_rep, "formerRepresentations", %{})

      assert {:error, _} = ObjectValidator.validate(external_rep, [])
    end

    test "edited note, badly-formed history item", %{external_rep: external_rep} do
      history_item =
        Enum.at(external_rep["formerRepresentations"]["orderedItems"], 0)
        |> Map.put("type", "Foo")

      external_rep =
        put_in(
          external_rep,
          ["formerRepresentations", "orderedItems"],
          [history_item]
        )

      assert {:error, _} = ObjectValidator.validate(external_rep, [])
    end
  end

  test "a Note from Roadhouse validates" do
    insert(:user, ap_id: "https://macgirvin.com/channel/mike")

    %{"object" => note} =
      "test/fixtures/roadhouse-create-activity.json"
      |> File.read!()
      |> Jason.decode!()

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "a Note from Convergence AP Bridge validates" do
    insert(:user, ap_id: "https://cc.mkdir.uk/ap/acct/hiira")

    note =
      "test/fixtures/ccworld-ap-bridge_note.json"
      |> File.read!()
      |> Jason.decode!()

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "a note with an attachment should work", _ do
    insert(:user, %{ap_id: "https://owncast.localhost.localdomain/federation/user/streamer"})

    note =
      "test/fixtures/owncast-note-with-attachment.json"
      |> File.read!()
      |> Jason.decode!()

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "a Note without replies/first/items validates" do
    insert(:user, ap_id: "https://mastodon.social/users/emelie")

    note =
      "test/fixtures/tesla_mock/status.emelie.json"
      |> File.read!()
      |> Jason.decode!()
      |> pop_in(["replies", "first", "items"])
      |> elem(1)

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "a Misskey MFM note is rendered from source content" do
    user = insert(:user, ap_id: "https://misskey.example/users/alice")

    note = %{
      "id" => "https://misskey.example/notes/1",
      "type" => "Note",
      "actor" => user.ap_id,
      "attributedTo" => user.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "original content",
      "context" => Utils.generate_context_id(),
      "source" => %{
        "content" => "$[spin.speed=1s mfm goes here] <script>alert('xss')</script>",
        "mediaType" => "text/x.misskeymarkdown"
      }
    }

    %{valid?: true, changes: %{content: content, source: source}} =
      ArticleNotePageValidator.cast_and_validate(note)

    assert source["mediaType"] == "text/x.misskeymarkdown"
    assert content =~ ~s(class="mfm-spin")
    assert content =~ ~s(data-mfm-speed="1s")
    assert content =~ "mfm goes here"
    refute content =~ "original content"
    refute content =~ "<script"
  end

  test "a Misskey MFM note resolves only cached AP mention tags" do
    remote_user = insert(:user, ap_id: "https://misskey.example/users/carol")
    local_user = insert(:user, nickname: "local_user")

    note = %{
      "id" => "https://misskey.example/notes/3",
      "type" => "Note",
      "actor" => remote_user.ap_id,
      "attributedTo" => remote_user.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "original content",
      "context" => Utils.generate_context_id(),
      "tag" => [
        %{
          "type" => "Mention",
          "name" => "@local_user",
          "href" => local_user.ap_id
        },
        %{
          "type" => "Mention",
          "name" => "@uncached",
          "href" => "https://misskey.example/users/uncached"
        }
      ],
      "source" => %{
        "content" => "@local_user @uncached $[spin hello]",
        "mediaType" => "text/x.misskeymarkdown"
      }
    }

    %{valid?: true, changes: %{content: content}} =
      ArticleNotePageValidator.cast_and_validate(note)

    assert content =~ local_user.ap_id
    assert content =~ "@uncached"
  end

  test "a Misskey MFM note drops oversized source content instead of parsing it" do
    user = insert(:user, ap_id: "https://misskey.example/users/oversized")

    note = %{
      "id" => "https://misskey.example/notes/4",
      "type" => "Note",
      "actor" => user.ap_id,
      "attributedTo" => user.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "<span class=\"mfm-spin\">safe fallback</span>",
      "context" => Utils.generate_context_id(),
      "source" => %{
        "content" => String.duplicate("x", 5_001),
        "mediaType" => "text/x.misskeymarkdown"
      }
    }

    %{valid?: true, changes: %{content: content, source: source}} =
      ArticleNotePageValidator.cast_and_validate(note)

    assert content == "<span class=\"mfm-spin\">safe fallback</span>"
    refute Map.has_key?(source, "content")
  end

  test "a note drops oversized non-MFM source content" do
    user = insert(:user, ap_id: "https://example.com/users/source")

    note = %{
      "id" => "https://example.com/notes/1",
      "type" => "Note",
      "actor" => user.ap_id,
      "attributedTo" => user.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "regular content",
      "context" => Utils.generate_context_id(),
      "source" => %{
        "content" => String.duplicate("x", 5_001),
        "mediaType" => "text/markdown"
      }
    }

    %{valid?: true, changes: %{source: source}} = ArticleNotePageValidator.cast_and_validate(note)

    assert source == %{"mediaType" => "text/markdown"}
  end

  test "a Misskey MFM note with legacy _misskey_content is rendered" do
    user = insert(:user, ap_id: "https://misskey.example/users/legacy")

    note = %{
      "id" => "https://misskey.example/notes/5",
      "type" => "Note",
      "actor" => user.ap_id,
      "attributedTo" => user.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" => "original content",
      "context" => Utils.generate_context_id(),
      "_misskey_content" => "$[spin legacy]"
    }

    %{valid?: true, changes: %{content: content, source: source}} =
      ArticleNotePageValidator.cast_and_validate(note)

    assert source == %{"content" => "$[spin legacy]", "mediaType" => "text/x.misskeymarkdown"}
    assert content =~ ~s(class="mfm-spin")
    assert content =~ "legacy"
  end

  test "a Misskey MFM note with htmlMfm is scrubbed but not rendered from source content" do
    user = insert(:user, ap_id: "https://misskey.example/users/bob")

    note = %{
      "id" => "https://misskey.example/notes/2",
      "type" => "Note",
      "actor" => user.ap_id,
      "attributedTo" => user.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "content" =>
        "<span class=\"mfm-spin\">already rendered</span><script>alert('xss')</script>",
      "htmlMfm" => true,
      "context" => Utils.generate_context_id(),
      "source" => %{
        "content" => String.duplicate("x", 5_001),
        "mediaType" => "text/x.misskeymarkdown"
      }
    }

    %{valid?: true, changes: %{content: content, htmlMfm: true, source: source}} =
      ArticleNotePageValidator.cast_and_validate(note)

    assert content == "<span class=\"mfm-spin\">already rendered</span>alert(&#39;xss&#39;)"
    refute Map.has_key?(source, "content")
  end

  test "a Note with validated likes collection validates" do
    insert(:user, ap_id: "https://pol.social/users/mkljczk")

    %{"object" => note} =
      "test/fixtures/mastodon-update-with-likes.json"
      |> File.read!()
      |> Jason.decode!()

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "Fedibird quote post" do
    insert(:user, ap_id: "https://fedibird.com/users/noellabo")

    data = File.read!("test/fixtures/quote_post/fedibird_quote_post.json") |> Jason.decode!()
    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://misskey.io/notes/8vsn2izjwh"
  end

  test "Fedibird quote post with quoteUri field" do
    insert(:user, ap_id: "https://fedibird.com/users/noellabo")

    data = File.read!("test/fixtures/quote_post/fedibird_quote_uri.json") |> Jason.decode!()
    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://fedibird.com/users/yamako/statuses/107699333438289729"
  end

  test "Misskey quote post" do
    insert(:user, ap_id: "https://misskey.io/users/7rkrarq81i")

    data = File.read!("test/fixtures/quote_post/misskey_quote_post.json") |> Jason.decode!()
    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://misskey.io/notes/8vs6wxufd0"
  end

  test "Parse tag as quote" do
    # https://codeberg.org/fediverse/fep/src/branch/main/fep/e232/fep-e232.md

    insert(:user, ap_id: "https://server.example/users/1")

    data = File.read!("test/fixtures/quote_post/fep-e232-tag-example.json") |> Jason.decode!()
    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://server.example/objects/123"

    assert Enum.at(cng.changes.tag, 0).changes == %{
             type: "Link",
             mediaType: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
             href: "https://server.example/objects/123",
             name: "RE: https://server.example/objects/123"
           }
  end

  describe "Note language" do
    test "it detects language from JSON-LD context" do
      user = insert(:user)

      note_activity = %{
        "@context" => ["https://www.w3.org/ns/activitystreams", %{"@language" => "pl"}],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "type" => "Create",
        "object" => %{
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "id" => Utils.generate_object_id(),
          "type" => "Note",
          "content" => "Szczęść Boże",
          "attributedTo" => user.ap_id
        },
        "actor" => user.ap_id
      }

      {:ok, _create_activity, meta} = ObjectValidator.validate(note_activity, [])

      assert meta[:object_data]["language"] == "pl"
    end

    test "it detects language from contentMap" do
      user = insert(:user)

      note = %{
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "id" => Utils.generate_object_id(),
        "type" => "Note",
        "content" => "Szczęść Boże",
        "contentMap" => %{
          "de" => "Gott segne",
          "pl" => "Szczęść Boże"
        },
        "attributedTo" => user.ap_id
      }

      {:ok, object} = ArticleNotePageValidator.cast_and_apply(note)

      assert object.language == "pl"
    end

    test "it doesn't call LanguageDetector when language is specified" do
      # Set up expectation that detect should not be called
      LanguageDetectorMock
      |> expect(:detect, 0, fn _ -> flunk("LanguageDetector.detect should not be called") end)
      |> stub(:missing_dependencies, fn -> [] end)
      |> stub(:configured?, fn -> true end)

      # Stub the StaticStubbedConfigMock to return our mock for the provider
      StaticStubbedConfigMock
      |> stub(:get, fn
        [Pleroma.Language.LanguageDetector, :provider] -> LanguageDetectorMock
        _other -> nil
      end)

      user = insert(:user)

      note = %{
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "id" => Utils.generate_object_id(),
        "type" => "Note",
        "content" => "a post in English",
        "contentMap" => %{
          "en" => "a post in English"
        },
        "attributedTo" => user.ap_id
      }

      ArticleNotePageValidator.cast_and_apply(note)
    end

    test "it adds contentMap if language is specified" do
      user = insert(:user)

      note = %{
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "id" => Utils.generate_object_id(),
        "type" => "Note",
        "content" => "тест",
        "language" => "uk",
        "attributedTo" => user.ap_id
      }

      {:ok, object} = ArticleNotePageValidator.cast_and_apply(note)

      assert object.contentMap == %{
               "uk" => "тест"
             }
    end
  end
end
