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
    setup do
      Enum.each(@configurable_features_flags, &clear_config(&1, false))
    end

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
end
