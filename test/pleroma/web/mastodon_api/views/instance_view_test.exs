# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.InstanceViewTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Language.LanguageDetectorMock
  alias Pleroma.StaticStubbedConfigMock
  alias Pleroma.Web.MastodonAPI.InstanceView

  import Mox

  @features [
    "pleroma_api",
    "mastodon_api",
    "mastodon_api_grouped_notifications",
    "mastodon_api_streaming",
    "polls",
    "v2_suggestions",
    "pleroma_explicit_addressing",
    "shareable_emoji_packs",
    "multifetch",
    "pleroma:api/v1/notifications:include_types_filter",
    "editing",
    "quote_posting",
    "pleroma_emoji_reactions",
    "pleroma_custom_emoji_reactions",
    "pleroma_chat_messages",
    "pleroma:pin_chats",
    "pleroma:get:main/ostatus",
    "pleroma:group_actors",
    "pleroma:bookmark_folders",
    "pleroma:block_expiration"
  ]

  @configureable_features [
    "blockers_visible",
    "media_proxy",
    "gopher",
    "chat",
    "shout",
    "relay",
    "safe_dm_mentions",
    "exposable_reactions",
    "profile_directory",
    "pleroma:language_detection"
  ]
  @configurable_features_flags [
    [:activitypub, :blockers_visible],
    [:media_proxy, :enabled],
    [:gopher, :enabled],
    [:shout, :enabled],
    [:instance, :allow_relay],
    [:instance, :safe_dm_mentions],
    [:instance, :show_reactions],
    [:instance, :profile_directory]
  ]

  # When this fails, a new feature flag was probably added. Add it to the macros above.
  describe "uncofigurable features" do
    setup do: Enum.each(@configurable_features_flags, &clear_config(&1, false))

    test "returns always enabled features" do
      features = @features

      assert Enum.sort(InstanceView.features()) == Enum.sort(features)
    end
  end

  describe "all features" do
    setup do
      Enum.each(@configurable_features_flags, &clear_config(&1, true))

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

      :ok
    end

    test "returns all features including configurable ones" do
      features = @features ++ @configureable_features

      assert Enum.sort(InstanceView.features()) == Enum.sort(features)
    end
  end

  describe "federation/0" do
    setup do: clear_config([:mrf, :transparency], true)

    test "quarantined instances" do
      clear_config([:instance, :quarantined_instances], [{"quarantine.example.com", "crimes"}])

      output = InstanceView.federation()
      assert %{quarantined_instances: ["quarantine.example.com"]} = output
      assert %{quarantined_instances_info:  %{"quarantined_instances" => %{"quarantine.example.com" => %{"reason" => "crimes"}}}} = output
    end

    test "rejected instances" do
      clear_config([:instance, :rejected_instances], [{"rejected.example.com", "not enough #cofe posting"}])

      output = InstanceView.federation()
      assert %{rejected_instances: %{"rejected.example.com" => %{"reason" => "not enough #cofe posting"}}} = output
    end

    test "federating" do
      clear_config([:instance, :federating], true)

      output = InstanceView.federation()
      assert %{enabled: true} = output
    end

    test "transparency" do
      clear_config([:instance, :quarantined_instances], [{"quarantine.example.com", "crimes"}])
      clear_config([:instance, :rejected_instances], [{"rejected.example.com", "not enough #cofe posting"}])
      clear_config([:instance, :federating], true)
      clear_config([:mrf, :transparency], false)

      output = InstanceView.federation()
      assert %{enabled: true} == output
    end

    test "MRFs" do
      clear_config([:mrf, :policies], [Pleroma.Web.ActivityPub.MRF.SimplePolicy])
      clear_config([:mrf, :transparency_exclusions], [{"media1.example.com", "the Fediverse doesn't need to know"}])
      clear_config([:mrf_simple, :media_removal], [{"media1.example.com", "NSFW"}, {"media2.example.com", "usual suspects"}])
      clear_config([:mrf_simple, :reject], [{"rejected.example.com", "not enough #cofe posting"}])

      output = InstanceView.federation()

      expected = %{
        mrf_simple: %{
          reject: ["rejected.example.com"],
          media_removal: ["media2.example.com"],
        },
        mrf_hashtag: %{
          sensitive: ["nsfw"],
        },
        exclusions: true,
        mrf_policies: ["SimplePolicy", "HashtagPolicy"],
        mrf_simple_info: %{
          reject: %{
            "rejected.example.com" => %{"reason" => "not enough #cofe posting"}
          },
          media_removal: %{"media2.example.com" => %{"reason" => "usual suspects"}}
        }
      }

      assert expected.mrf_simple.reject == output.mrf_simple.reject
      assert expected.mrf_simple.media_removal == output.mrf_simple.media_removal
      assert expected.mrf_simple_info == output.mrf_simple_info
      assert expected.exclusions == output.exclusions
    end
  end

  describe "render rule.json" do
    setup do
      rule = Pleroma.Rule.create(%{text: "hambaga"})

      %{rule: rule}
    end

    test "renders properly", %{rule: rule} do
      output = InstanceView.render("rule.json", %{rule: rule})

      assert %{text: "hambaga"} = output
    end
  end

  describe "render rules.json" do
    setup do
      Pleroma.Rule.create(%{text: "rule 1"})
      Pleroma.Rule.create(%{text: "rule 2"})
      Pleroma.Rule.create(%{text: "rule 3"})
      Pleroma.Rule.create(%{text: "rule 4"})

      :ok
    end

    test "renders properly" do
      output = InstanceView.render("rules.json", %{})
      keys = Enum.map(output, fn %{text: text} -> text end)

      assert length(keys) == 4
      assert Enum.all?(output, fn %{text: "rule " <> num} -> String.to_integer(num) end)
    end
  end

  describe "render domain_blocks.json" do
    setup do
      clear_config([:mrf, :transparency], true)
      clear_config([:mrf, :transparency_exclusions], [{"removed1.example.com", "the Fediverse doesn't need to know"}])
      clear_config([:mrf_simple, :media_removal], [{"media1.example.com", "NSFW"}])
      clear_config([:mrf_simple, :reject], [{"rejected.example.com", "not enough #cofe posting"}, {"rejected-without-reason.example.com", ""}])
      clear_config([:mrf_simple, :federated_timeline_removal], [{"removed1.example.com", "spam"}, {"removed2.example.com", "more spam"}])

      :ok
    end

    test "renders properly" do
      output = InstanceView.render("domain_blocks.json", %{})

      # Media removal is not in @block_severities in the view.
      # NOTE: Order of these two matters!
      expected = [
        %{
          domain: "removed2.example.com",
          comment: "more spam",
          severity: "silence",
          digest: "5f6649cfc780fac5172dbbcc8a552953f6621a14368d82728b6e8faf51295dc0"
        },
        %{
          domain: "rejected.example.com",
          comment: "not enough #cofe posting",
          severity: "suspend",
          digest: "c15082d347fb7eccd251e199a98dcdce94a8dfc1d33d6ece80889eed374b6f92"
        },
        %{
          domain: "rejected-without-reason.example.com",
          severity: "suspend",
          digest: "48297155018c626c8867ca0bba4a2621eccdf51c6f7ac91b7099ed8b2ee9863f"
        }
      ]

      assert expected == output
    end
  end

  describe "render translation_languages.json" do
    setup do: clear_config([Pleroma.Language.Translation, :provider], TranslationMock)

    test "returns language matrix" do
      output = InstanceView.render("translation_languages.json", %{})

      assert %{"en" => ["pl"], "pl" => ["en"]} == output
    end
  end
end
