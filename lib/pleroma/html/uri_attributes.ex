# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTML.URIAttributes do
  @moduledoc """
  URI attribute rules for the scrubbers.

  Works like `FastSanitize.Sanitizer.Meta.allow_tag_with_uri_attributes/3`, but
  checks the scheme the way a browser reads the URL. Browsers remove tabs and
  newlines anywhere and control characters and spaces at the start, so
  `java\\tscript:` is a `javascript:` link to them, while `URI.parse/1` finds no
  scheme and FastSanitize lets it through.
  """

  defmacro allow_tag_with_uri_attributes(tag, attrs, valid_schemes) do
    for attr <- attrs do
      quote do
        def scrub_attribute(unquote(tag), {unquote(attr), "&" <> _}), do: nil

        def scrub_attribute(unquote(tag), {unquote(attr), uri} = attribute) do
          if Pleroma.HTML.URIAttributes.valid_scheme?(uri, unquote(valid_schemes)),
            do: attribute
        end
      end
    end
  end

  @spec valid_scheme?(String.t(), [String.t()]) :: boolean()
  def valid_scheme?(uri, valid_schemes) do
    scheme =
      uri
      |> String.replace(~r/[\t\n\r]/, "")
      |> String.replace(~r/\A[\x00-\x20]+/, "")
      |> URI.parse()
      |> Map.get(:scheme)

    is_nil(scheme) or scheme in valid_schemes
  end
end
