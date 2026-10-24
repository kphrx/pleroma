# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.Schemas.PreviewCard do
  alias OpenApiSpex.Schema
  alias Pleroma.Web.ApiSpec.Schemas.Account

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PreviewCard",
    description: "Preview card for a link included within status or chat message content",
    type: :object,
    required: [
      :url,
      :title,
      :description,
      :language,
      :type,
      :authors,
      :author_name,
      :author_url,
      :provider_name,
      :provider_url,
      :html,
      :width,
      :height,
      :image,
      :image_description,
      :embed_url,
      :blurhash,
      :published_at
    ],
    properties: %{
      url: %Schema{type: :string, format: :uri, description: "Location of linked resource"},
      title: %Schema{type: :string, description: "Title of linked resource"},
      description: %Schema{type: :string, description: "Description of preview"},
      language: %Schema{
        type: :string,
        nullable: true,
        description: "Language of the linked resource"
      },
      type: %Schema{
        type: :string,
        enum: ["link", "photo", "video", "rich"],
        description: "The type of the preview card"
      },
      authors: %Schema{
        type: :array,
        description: "Fediverse accounts of the authors of the original resource",
        items: %Schema{
          type: :object,
          required: [:name, :url, :account],
          properties: %{
            name: %Schema{type: :string},
            url: %Schema{type: :string},
            account: %Schema{allOf: [Account], nullable: true}
          }
        }
      },
      author_name: %Schema{type: :string, description: "Author of the original resource"},
      author_url: %Schema{
        type: :string,
        description: "Link to the author of the original resource"
      },
      provider_name: %Schema{
        type: :string,
        description: "The provider of the original resource"
      },
      provider_url: %Schema{
        type: :string,
        description: "A link to the provider of the original resource"
      },
      html: %Schema{
        type: :string,
        format: :html,
        description: "HTML to be used for generating the preview card"
      },
      width: %Schema{type: :integer, description: "Width of preview, in pixels"},
      height: %Schema{type: :integer, description: "Height of preview, in pixels"},
      image: %Schema{
        type: :string,
        nullable: true,
        format: :uri,
        description: "Preview thumbnail"
      },
      image_description: %Schema{
        type: :string,
        description: "Alternate text that describes what is in the thumbnail"
      },
      embed_url: %Schema{
        type: :string,
        description: "Used for photo embeds, instead of custom `html`"
      },
      blurhash: %Schema{
        type: :string,
        nullable: true,
        description:
          "A hash computed by the [BlurHash algorithm](https://github.com/woltapp/blurhash), for generating colorful preview thumbnails when media has not been downloaded yet."
      },
      published_at: %Schema{
        type: :string,
        nullable: true,
        description: "Publication date of the linked resource"
      }
    }
  })
end
