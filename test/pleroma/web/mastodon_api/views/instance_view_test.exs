# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.InstanceViewTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.Language.LanguageDetectorMock
  alias Pleroma.StaticStubbedConfigMock
  alias Pleroma.Web.MastodonAPI.InstanceView

  import Mox

  @atom_common_information_keys [
    :languages,
    :rules,
    :title,
    :version
  ]

  @common_information_keys Enum.map(@atom_common_information_keys, &to_string/1)

  @atom_configuration_keys [
    :accounts,
    :statuses,
    :media_attachments,
    :polls
  ]

  @atom_configuration2_keys @atom_configuration_keys ++ [
    :urls,
    :vapid,
    :translation,
    :timelines_access
  ]

  @atom_pleroma_configuration_keys [
    :metadata,
    :stats,
    :vapid_public_key
  ]

  # TODO: Simplify this, so ideally only atoms are macroed
  @show_keys @common_information_keys ++ [
    "uri",
    "description",
    "short_description",
    "email",
    "urls",
    "stats",
    "thumbnail",
    "registrations",
    "approval_required",
    "contact_account",
    "configuration",
    # Extra (not present in Mastodon)"
    "max_toot_chars",
    "max_media_attachments",
    "poll_limits",
    "upload_limit",
    "avatar_upload_limit",
    "background_upload_limit",
    "banner_upload_limit",
    "background_image",
    "shout_limit",
    "description_limit",
    "chat_limit",
    "pleroma"
  ]

  @show2_keys @common_information_keys ++ [
      "domain",
      "source_url",
      "description",
      "usage",
      "thumbnail",
      "configuration",
      "registrations",
      "contact",
      # Extra (not present in Mastodon):
      "pleroma"
    ]

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

  defp check_common_information(info) do
    filtered_info = Map.reject(info, fn {key, _value} -> key not in @atom_common_information_keys end)

    expected = %{
      languages: ["en", "cs"],
      rules: InstanceView.render("rules.json", %{}),
      title: "test title",
      version: InstanceView.mastodon_api_level() <> " (compatible; #{Pleroma.Application.named_version()})"
    }

    Map.equal?(expected, filtered_info)
  end

  defp check_thumbnail(info) do
    thumbnail = info[:thumbnail]

    expected = %{
      url: URI.merge(Pleroma.Web.Endpoint.url(), "https://example.com/thumbnail.png") |> to_string
    }

    expected == thumbnail
  end

  defp check_contact(info, user) do
    contact = info[:contact]

    expected = %{
      email: "nonexist@example.com",
      account: Pleroma.Web.MastodonAPI.AccountView.render("show.json", %{user: user, for: nil})
    }

    Map.equal?(expected, contact)
  end

  defp check_contact_name(info, user) do
    contact = info[:contact_account]
    view = Pleroma.Web.MastodonAPI.AccountView.render("show.json", %{user: user, for: nil})

    contact == view
  end

  defp check_configuration(info) do
    configuration = info[:configuration]
    filtered_configuration = Map.reject(configuration, fn {key, _value} -> key not in @atom_configuration_keys end)

    expected = %{
      accounts: %{
        max_featured_tags: 0
      },
      statuses: %{
        max_characters: 4096,
        max_media_attachments: 1
      },
      media_attachments: %{
        image_size_limit: 1024,
        video_size_limit: 1024,
        supported_mime_types: ["application/octet-stream"]
      },
      polls: %{
        max_options: 4,
        max_characters_per_option: 120,
        min_expiration: 1,
        max_expiration: 2
      }
    }

    Map.equal?(expected, filtered_configuration)
  end

  defp check_configuration2(info) do
    configuration = info[:configuration]
    filtered_configuration = Map.reject(configuration, fn {key, _value} -> key not in @atom_configuration2_keys end)

    # configuration2 also includes parts from configuration
    expected = %{
      accounts: %{
        max_featured_tags: 0,
        max_pinned_statuses: 1,
        max_profile_fields: 1,
        profile_field_name_limit: 1,
        profile_field_value_limit: 1
      },
      statuses: %{
        max_characters: 4096,
        max_media_attachments: 1,
        characters_reserved_per_url: 0
      },
      media_attachments: %{
        image_size_limit: 1024,
        video_size_limit: 1024,
        supported_mime_types: ["application/octet-stream"]
      },
      polls: %{
        max_options: 4,
        max_characters_per_option: 120,
        min_expiration: 1,
        max_expiration: 2
      },
      urls: %{
        streaming: Pleroma.Web.Endpoint.websocket_url(),
        status: "https://status.example.com"
      },
      vapid: %{
        public_key: Keyword.get(Pleroma.Web.Push.vapid_config(), :public_key)
      },
      translation: %{enabled: true},
      timelines_access: %{
        live_feeds: %{local: "authenticated", remote: "authenticated"},
        hashtag_feeds: %{local: "authenticated", remote: "authenticated"},
        # not implemented in Pleroma
        trending_link_feeds: %{
          local: "disabled",
          remote: "disabled"
        }
      }
    }

    Map.equal?(expected, filtered_configuration)
  end

  defp check_registrations(info) do
    registrations = info[:registrations]

    expected = %{
      enabled: false,
      approval_required: true,
      message: nil,
      url: nil
    }

    Map.equal?(expected, registrations)
  end

  defp check_pleroma_configuration(info) do
    configuration = info[:pleroma]
    filtered_configuration = Map.reject(configuration, fn {key, _value} -> key not in @atom_pleroma_configuration_keys end)
    metadata = Map.fetch!(filtered_configuration, :metadata)
    # Tested elsewhere already
    filtered_metadata = Map.reject(metadata, fn {key, _value} -> key in [:features, :federation] end)
    filtered_configuration = %{filtered_configuration | metadata: filtered_metadata}

    expected = %{
      metadata: %{
        account_activation_required: true,
        fields_limits: %{
          max_fields: 1,
          max_remote_fields: 1,
          name_length: 1,
          value_length: 1
        },
        post_formats: ["text/plain"],
        birthday_required: true,
        birthday_min_age: 1,
        translation:
          %{
            source_languages: ["en", "pl"],
            target_languages: ["en", "pl"]
          },
        base_urls: %{
          media_proxy: "https://mediaproxy.example.com",
          upload: "https://upload.example.com"
        },
        markup: %{
            allow_inline_images: true,
            allow_headings: true,
            allow_tables: true
        }
      },
      stats: %{mau: Pleroma.User.active_user_count()},
      vapid_public_key: Keyword.get(Pleroma.Web.Push.vapid_config(), :public_key)
    }

    Map.equal?(expected, filtered_configuration)
  end

  defp check_pleroma_configuration2(info) do
    configuration = info[:pleroma]
    filtered_configuration = Map.reject(configuration, fn {key, _value} -> key not in @atom_pleroma_configuration_keys end)
    metadata = Map.fetch!(filtered_configuration, :metadata)
    # Tested elsewhere already
    filtered_metadata = Map.reject(metadata, fn {key, _value} -> key in [:features, :federation] end)
    filtered_configuration = %{filtered_configuration | metadata: filtered_metadata}

    # pleroma_configuration2 also includes parts from pleroma_configuration
    expected = %{
      metadata: %{
        account_activation_required: true,
        fields_limits: %{
          max_fields: 1,
          max_remote_fields: 1,
          name_length: 1,
          value_length: 1
        },
        post_formats: ["text/plain"],
        birthday_required: true,
        birthday_min_age: 1,
        translation:
          %{
            source_languages: ["en", "pl"],
            target_languages: ["en", "pl"]
          },
        base_urls: %{
          media_proxy: "https://mediaproxy.example.com",
          upload: "https://upload.example.com"
        },
        markup: %{
            allow_inline_images: true,
            allow_headings: true,
            allow_tables: true
        },
        avatar_upload_limit: 1024,
        background_upload_limit: 1024,
        banner_upload_limit: 1024,
        background_image: Pleroma.Web.Endpoint.url() <> "/media/background.png",
        chat_limit: 120,
        description_limit: 120,
        shout_limit: 120
      },
      stats: %{mau: Pleroma.User.active_user_count()},
      vapid_public_key: Keyword.get(Pleroma.Web.Push.vapid_config(), :public_key)
    }

    Map.equal?(expected, filtered_configuration)
  end

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

  describe "render show.json/show2.json" do
    setup do
      Pleroma.Rule.create(%{text: "rule 1"})
      Pleroma.Rule.create(%{text: "rule 2"})

      user = insert(:user)

      # Wall of configs for testing whether they are rendered properly
      clear_config([Pleroma.Language.Translation, :provider], TranslationMock)

      clear_config([:instance, :languages], ["en", "cs"])
      clear_config([:instance, :name], "test title")
      clear_config([:instance, :contact_username], user.nickname)
      clear_config([:instance, :limit], 4096)
      clear_config([:instance, :max_media_attachments], 1)
      clear_config([:instance, :upload_limit], 1024)
      clear_config([:instance, :poll_limits, :max_options], 4)
      clear_config([:instance, :poll_limits, :max_option_chars], 120)
      clear_config([:instance, :poll_limits, :min_expiration], 1)
      clear_config([:instance, :poll_limits, :max_expiration], 2)
      clear_config([:instance, :account_activation_required], true)
      clear_config([:instance, :max_account_fields], 1)
      clear_config([:instance, :max_remote_account_fields], 1)
      clear_config([:instance, :account_field_name_length], 1)
      clear_config([:instance, :account_field_value_length], 1)
      clear_config([:instance, :allowed_post_formats], ["text/plain"])
      clear_config([:instance, :birthday_required], true)
      clear_config([:instance, :birthday_min_age], 1)

      clear_config([:instance, :short_description], "Corndog Emporium!")
      clear_config([:instance, :instance_thumbnail], "https://example.com/thumbnail.png")
      clear_config([:instance, :registrations_open], false)
      clear_config([:instance, :account_approval_required], true)

      clear_config([:instance, :max_pinned_statuses], 1)
      clear_config([:instance, :status_page], "https://status.example.com")

      clear_config([:instance, :email], "nonexist@example.com")

      clear_config([:instance, :avatar_upload_limit], 1024)
      clear_config([:instance, :background_upload_limit], 1024)
      clear_config([:instance, :banner_upload_limit], 1024)
      clear_config([:instance, :background_image], "/media/background.png")
      clear_config([:instance, :chat_limit], 120)
      clear_config([:instance, :description_limit], 120)

      clear_config([:media_proxy, :enabled], true)
      clear_config([:media_proxy, :base_url], "https://mediaproxy.example.com")

      clear_config([Pleroma.Upload, :base_url], "https://upload.example.com")

      clear_config([:markup, :allow_inline_images], true)
      clear_config([:markup, :allow_headings], true)
      clear_config([:markup, :allow_tables], true)

      clear_config([:restrict_unauthenticated, :timelines], %{local: true, federated: true})

      clear_config([:shout, :limit], 120)

      %{user: user}
    end

    test "renders show.json properly", %{user: user} do
      output = InstanceView.render("show.json", %{})
      expected_keys = Enum.sort(@show_keys)

      assert check_common_information(output)
      assert check_contact_name(output, user)
      assert check_configuration(output)
      assert check_pleroma_configuration(output)
      assert expected_keys == Enum.sort(Enum.map(Map.keys(output), &to_string/1))
    end

    test "renders show2.json properly", %{user: user} do
      output = InstanceView.render("show2.json", %{})
      expected_keys = Enum.sort(@show2_keys)

      assert check_common_information(output)
      assert check_thumbnail(output)
      assert check_configuration2(output)
      assert check_registrations(output)
      assert check_contact(output, user)
      assert check_pleroma_configuration2(output)
      assert expected_keys == Enum.sort(Enum.map(Map.keys(output), &to_string/1))
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
