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

  @common_information_keys [
    :languages,
    :rules,
    :title,
    :version
  ]

  # Used for filtering out values from configuration.json render in configuration2.json render
  @configuration2_filter [
    {:accounts,
     [
       :max_pinned_statuses,
       :max_profile_fields,
       :profile_field_name_limit,
       :profile_field_value_limit
     ]},
    {:statuses, [:characters_reserved_per_url]},
    {:urls, [:streaming, :status]},
    {:vapid, [:public_key]},
    {:translation, [:enabled]},
    {:timelines_access, [:live_feeds, :hashtag_feeds, :trending_link_feeds]}
  ]

  @pleroma_configuration_filter [{:metadata, [:features, :federation]}]

  @pleroma_configuration2_filter [
    {:metadata,
     [
       :avatar_upload_limit,
       :background_upload_limit,
       :banner_upload_limit,
       :background_image,
       :chat_limit,
       :description_limit,
       :shout_limit
     ]}
  ]

  @show_keys @common_information_keys ++
               [
                 :uri,
                 :description,
                 :short_description,
                 :email,
                 :urls,
                 :stats,
                 :thumbnail,
                 :registrations,
                 :approval_required,
                 :contact_account,
                 :configuration,
                 # Extra (not present in Mastodon)
                 :max_toot_chars,
                 :max_media_attachments,
                 :poll_limits,
                 :upload_limit,
                 :avatar_upload_limit,
                 :background_upload_limit,
                 :banner_upload_limit,
                 :background_image,
                 :shout_limit,
                 :description_limit,
                 :chat_limit,
                 :pleroma
               ]

  # Checked in other check_* functions
  @show_filter @common_information_keys ++ [:contact_account, :configuration, :pleroma]

  @show2_keys @common_information_keys ++
                [
                  :domain,
                  :source_url,
                  :description,
                  :usage,
                  :thumbnail,
                  :configuration,
                  :registrations,
                  :contact,
                  # Extra (not present in Mastodon)
                  :pleroma
                ]

  @show2_filter @common_information_keys ++
                  [:thumbnail, :configuration, :registrations, :contact, :pleroma]

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
    "pleroma:get:main/ostatus",
    "pleroma:group_actors",
    "pleroma:bookmark_folders",
    "pleroma:block_expiration"
  ]

  @configurable_features [
    "blockers_visible",
    "media_proxy",
    "gopher",
    "chat",
    "shout",
    "pleroma_chat_messages",
    "pleroma:pin_chats",
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
    [Pleroma.Chat, :enabled],
    [:instance, :allow_relay],
    [:instance, :safe_dm_mentions],
    [:instance, :show_reactions],
    [:instance, :profile_directory]
  ]

  # Filters out values from one layer deep nested Maps.
  # Filtering types:
  #   - :inclusive -> filters out everything that is not in the filters
  #   - :discriminative -> filters out what is in the filters
  defp filter_render(input, filter, type, acc)

  defp filter_render(_input_rest, [], type, acc) when type == :inclusive, do: acc

  defp filter_render(input_rest, [], type, acc) when type == :discriminative,
    do: Map.merge(input_rest, acc)

  defp filter_render(input, filter, type, acc) do
    {{filter_key, filters}, filter_rest} = List.pop_at(filter, 0)
    {config_key_values, input_rest} = Map.pop!(input, filter_key)

    filtered =
      case type do
        :inclusive ->
          Map.reject(config_key_values, fn {key, _} -> key not in filters end)

        :discriminative ->
          Map.reject(config_key_values, fn {key, _} -> key in filters end)
      end

    filter_render(input_rest, filter_rest, type, Map.put(acc, filter_key, filtered))
  end

  defp check_common_information(info) do
    filtered_info = Map.reject(info, fn {key, _value} -> key not in @common_information_keys end)

    expected = %{
      languages: ["en"],
      rules: InstanceView.render("rules.json", %{}),
      title: "Pleroma",
      version:
        InstanceView.mastodon_api_level() <>
          " (compatible; #{Pleroma.Application.named_version()})"
    }

    Map.equal?(expected, filtered_info)
  end

  defp check_thumbnail2(info) do
    thumbnail = info[:thumbnail]

    expected = %{
      url:
        URI.merge(Pleroma.Web.Endpoint.url(), "http://localhost:4001/instance/thumbnail.jpeg")
        |> to_string
    }

    expected == thumbnail
  end

  defp check_contact(info, user) do
    contact = info[:contact]

    expected = %{
      email: "admin@example.com",
      account: Pleroma.Web.MastodonAPI.AccountView.render("show.json", %{user: user, for: nil})
    }

    Map.equal?(expected, contact)
  end

  defp check_contact_account(info, user) do
    contact = info[:contact_account]
    view = Pleroma.Web.MastodonAPI.AccountView.render("show.json", %{user: user, for: nil})

    contact == view
  end

  defp check_configuration(info) do
    configuration = info[:configuration]

    expected = %{
      accounts: %{
        max_featured_tags: 0
      },
      statuses: %{
        max_characters: 5_000,
        max_media_attachments: 1_000
      },
      media_attachments: %{
        image_size_limit: 16_000_000,
        video_size_limit: 16_000_000,
        supported_mime_types: ["application/octet-stream"]
      },
      polls: %{
        max_options: 20,
        max_characters_per_option: 200,
        min_expiration: 0,
        max_expiration: 365 * 24 * 60 * 60
      }
    }

    Map.equal?(expected, configuration)
  end

  defp check_configuration2(info) do
    configuration =
      info[:configuration]
      |> filter_render(@configuration2_filter, :inclusive, %{})

    expected = %{
      accounts: %{
        max_pinned_statuses: 1,
        max_profile_fields: 10,
        profile_field_name_limit: 512,
        profile_field_value_limit: 2048
      },
      statuses: %{
        characters_reserved_per_url: 0
      },
      urls: %{
        streaming: Pleroma.Web.Endpoint.websocket_url(),
        status: nil
      },
      vapid: %{
        public_key: Keyword.get(Pleroma.Web.Push.vapid_config(), :public_key)
      },
      translation: %{enabled: true},
      timelines_access: %{
        live_feeds: %{local: "public", remote: "public"},
        hashtag_feeds: %{local: "public", remote: "public"},
        # not implemented in Pleroma
        trending_link_feeds: %{
          local: "disabled",
          remote: "disabled"
        }
      }
    }

    Map.equal?(expected, configuration)
  end

  defp check_registrations2(info) do
    registrations = info[:registrations]

    expected = %{
      enabled: true,
      approval_required: false,
      message: nil,
      url: nil
    }

    Map.equal?(expected, registrations)
  end

  defp check_pleroma_configuration(info) do
    configuration =
      info[:pleroma]
      |> filter_render(@pleroma_configuration_filter, :discriminative, %{})

    expected = %{
      metadata: %{
        account_activation_required: false,
        fields_limits: %{
          max_fields: 10,
          max_remote_fields: 20,
          name_length: 512,
          value_length: 2048
        },
        post_formats: [
          "text/plain",
          "text/html",
          "text/markdown",
          "text/bbcode",
          "text/x.misskeymarkdown"
        ],
        birthday_required: false,
        birthday_min_age: 0,
        translation: %{
          source_languages: ["en", "pl"],
          target_languages: ["en", "pl"]
        },
        base_urls: %{},
        markup: %{
          allow_inline_images: true,
          allow_headings: false,
          allow_tables: false
        }
      },
      stats: %{mau: Pleroma.User.active_user_count()},
      vapid_public_key: Keyword.get(Pleroma.Web.Push.vapid_config(), :public_key)
    }

    Map.equal?(expected, configuration)
  end

  defp check_pleroma_configuration2(info) do
    configuration =
      info[:pleroma]
      |> filter_render(@pleroma_configuration2_filter, :inclusive, %{})

    expected = %{
      metadata: %{
        avatar_upload_limit: 2_000_000,
        background_upload_limit: 4_000_000,
        banner_upload_limit: 4_000_000,
        background_image: Pleroma.Web.Endpoint.url() <> "/images/city.jpg",
        chat_limit: 5_000,
        description_limit: 5_000,
        shout_limit: 5_000
      }
    }

    Map.equal?(expected, configuration)
  end

  defp check_show(info) do
    filter = @show_filter
    filtered_info = Map.reject(info, fn {key, _value} -> key in filter end)

    expected = %{
      uri: Pleroma.Web.WebFinger.host(),
      description: "Pleroma: An efficient and flexible fediverse server",
      short_description: "",
      email: "admin@example.com",
      urls: %{
        streaming_api: Pleroma.Web.Endpoint.websocket_url()
      },
      stats: Pleroma.Stats.get_stats(),
      thumbnail: "http://localhost:4001/instance/thumbnail.jpeg",
      registrations: true,
      approval_required: false,
      max_toot_chars: 5_000,
      max_media_attachments: 1_000,
      poll_limits: %{
        max_options: 20,
        max_option_chars: 200,
        min_expiration: 0,
        max_expiration: 365 * 24 * 60 * 60
      },
      upload_limit: 16_000_000,
      avatar_upload_limit: 2_000_000,
      background_upload_limit: 4_000_000,
      banner_upload_limit: 4_000_000,
      background_image: Pleroma.Web.Endpoint.url() <> "/images/city.jpg",
      shout_limit: 5_000,
      description_limit: 5_000,
      chat_limit: 5_000
    }

    Map.equal?(expected, filtered_info)
  end

  defp check_show2(info) do
    filter = @show2_filter
    filtered_info = Map.reject(info, fn {key, _value} -> key in filter end)

    expected = %{
      domain: Pleroma.Web.WebFinger.host(),
      source_url: Pleroma.Application.repository(),
      description: "",
      usage: %{users: %{active_month: Pleroma.User.active_user_count()}}
    }

    Map.equal?(expected, filtered_info)
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
      features = @features ++ @configurable_features

      assert Enum.sort(InstanceView.features()) == Enum.sort(features)
    end
  end

  describe "chat features" do
    test "advertises Shout without Chats" do
      clear_config([:shout, :enabled], true)
      clear_config([Pleroma.Chat, :enabled], false)

      features = InstanceView.features()

      assert "chat" in features
      assert "shout" in features
      refute "pleroma_chat_messages" in features
      refute "pleroma:pin_chats" in features
    end

    test "advertises Chats without Shout" do
      clear_config([:shout, :enabled], false)
      clear_config([Pleroma.Chat, :enabled], true)

      features = InstanceView.features()

      refute "chat" in features
      refute "shout" in features
      assert "pleroma_chat_messages" in features
      assert "pleroma:pin_chats" in features
    end
  end

  describe "federation/0" do
    setup do: clear_config([:mrf, :transparency], true)

    test "quarantined instances" do
      clear_config([:instance, :quarantined_instances], [{"quarantine.example.com", "crimes"}])

      output = InstanceView.federation()
      assert %{quarantined_instances: ["quarantine.example.com"]} = output

      assert %{
               quarantined_instances_info: %{
                 "quarantined_instances" => %{"quarantine.example.com" => %{"reason" => "crimes"}}
               }
             } = output
    end

    test "rejected instances" do
      clear_config([:instance, :rejected_instances], [
        {"rejected.example.com", "not enough #cofe posting"}
      ])

      output = InstanceView.federation()

      assert %{
               rejected_instances: %{
                 "rejected.example.com" => %{"reason" => "not enough #cofe posting"}
               }
             } = output
    end

    test "federating" do
      clear_config([:instance, :federating], true)

      output = InstanceView.federation()
      assert %{enabled: true} = output
    end

    test "transparency" do
      clear_config([:instance, :quarantined_instances], [{"quarantine.example.com", "crimes"}])
      clear_config([:instance, :federating], true)
      clear_config([:mrf, :transparency], false)

      clear_config([:instance, :rejected_instances], [
        {"rejected.example.com", "not enough #cofe posting"}
      ])

      output = InstanceView.federation()
      assert %{enabled: true} == output
    end

    test "MRFs" do
      clear_config([:mrf, :policies], [Pleroma.Web.ActivityPub.MRF.SimplePolicy])
      clear_config([:mrf_simple, :reject], [{"rejected.example.com", "not enough #cofe posting"}])

      clear_config([:mrf, :transparency_exclusions], [
        {"media1.example.com", "the Fediverse doesn't need to know"}
      ])

      clear_config([:mrf_simple, :media_removal], [
        {"media1.example.com", "NSFW"},
        {"media2.example.com", "usual suspects"}
      ])

      output = InstanceView.federation()

      expected = %{
        mrf_simple: %{
          reject: ["rejected.example.com"],
          media_removal: ["media2.example.com"]
        },
        mrf_hashtag: %{
          sensitive: ["nsfw"]
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

      # contact in show2.json
      clear_config([:instance, :contact_username], user.nickname)

      # Pleroma.Language.Translation.configured?() -> true
      clear_config([Pleroma.Language.Translation, :provider], TranslationMock)

      # Deprecated, but still used in view
      clear_config([:instance, :chat_limit], 5_000)

      %{user: user}
    end

    test "renders show.json properly", %{user: user} do
      output = InstanceView.render("show.json", %{})
      expected_keys = Enum.sort(@show_keys)

      assert check_common_information(output)
      assert check_show(output)
      assert check_contact_account(output, user)
      assert check_configuration(output)
      assert check_pleroma_configuration(output)
      assert expected_keys == Enum.sort(Map.keys(output))
    end

    test "renders show2.json properly", %{user: user} do
      output = InstanceView.render("show2.json", %{})
      expected_keys = Enum.sort(@show2_keys)

      assert check_common_information(output)
      assert check_show2(output)
      assert check_thumbnail2(output)
      assert check_configuration2(output)
      assert check_registrations2(output)
      assert check_contact(output, user)
      assert check_pleroma_configuration2(output)
      assert expected_keys == Enum.sort(Map.keys(output))
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
      clear_config([:mrf_simple, :media_removal], [{"media1.example.com", "NSFW"}])

      clear_config([:mrf, :transparency_exclusions], [
        {"removed1.example.com", "the Fediverse doesn't need to know"}
      ])

      clear_config([:mrf_simple, :reject], [
        {"rejected.example.com", "not enough #cofe posting"},
        {"rejected-without-reason.example.com", ""}
      ])

      clear_config([:mrf_simple, :federated_timeline_removal], [
        {"removed1.example.com", "spam"},
        {"removed2.example.com", "more spam"}
      ])

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
