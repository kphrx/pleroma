# Pleroma: A lightweight social networking server
# Copyright © 2017-2025 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Utils.URIEncoding do
  @moduledoc """
    Utility functions for dealing with URI encoding of paths and queries
    with support for query-encoding quirks.
  """
  require Pleroma.Constants

  # We don't always want to decode the path first, like is the case in
  # Pleroma.Upload.url_from_spec/3.
  def encode_url(url, opts \\ []) when is_binary(url) and is_list(opts) do
    bypass_parse = Keyword.get(opts, :bypass_parse, false)
    bypass_decode = Keyword.get(opts, :bypass_decode, false)

    cond do
      bypass_parse ->
        encode_path(url, bypass_decode)

      true ->
        URI.parse(url)
        |> then(fn parsed ->
          path = encode_path(parsed.path, bypass_decode)

          query = encode_query(parsed.query)

          %{parsed | path: path, query: query}
        end)
        |> URI.to_string()
    end
  end

  defp encode_path(nil, _bypass_decode), do: nil

  # URI.encode/2 deliberately does not encode all chars that are forbidden
  # in the path component of a URI. It only encodes chars that are forbidden
  # in the whole URI. A predicate in the 2nd argument is used to fix that here.
  # URI.encode/2 uses the predicate function to determine whether each byte
  # (in an integer representation) should be encoded or not.
  defp encode_path(path, bypass_decode) when is_binary(path) do
    path =
      cond do
        bypass_decode ->
          path

        true ->
          URI.decode(path)
      end

    path
    |> URI.encode(fn byte ->
      URI.char_unreserved?(byte) ||
        Enum.any?(
          Pleroma.Constants.uri_path_allowed_reserved_chars(),
          fn char ->
            char == byte
          end
        )
    end)
  end

  defp encode_query(nil), do: nil

  # Order of kv pairs in query is not preserved when using URI.decode_query.
  # URI.query_decoder/2 returns a stream which so far appears to not change order.
  # Immediately switch to a list to prevent breakage for sites that expect
  # the order of query keys to be always the same.
  defp encode_query(query) when is_binary(query) do
    query
    |> URI.query_decoder()
    |> Enum.to_list()
    |> do_encode_query()
  end

  # Always uses www_form encoding
  defp do_encode_query(enumerable) do
    Enum.map_join(enumerable, "&", &maybe_apply_query_quirk(&1))
  end

  defp maybe_apply_query_quirk({key, value}) do
    case key do
      "precrop" ->
        query_encode_kv_pair({key, value}, ~c":,")

      key ->
        query_encode_kv_pair({key, value})
    end
  end

  defp query_encode_kv_pair({key, value}, rules \\ []) when is_list(rules) do
    cond do
      length(rules) > 0 ->
        # URI.encode_query/2 does not appear to follow spec and encodes all parts
        # of our URI path Constant. This appears to work outside of edge-cases
        # like The Guardian Rich Media Cards, keeping behavior same as with
        # URI.encode_query/2 unless otherwise specified via rules.
        (URI.encode_www_form(Kernel.to_string(key)) <>
           "=" <>
           URI.encode(value, fn byte ->
             URI.char_unreserved?(byte) ||
               Enum.any?(
                 rules,
                 fn char ->
                   char == byte
                 end
               )
           end))
        |> String.replace("%20", "+")

      true ->
        URI.encode_www_form(Kernel.to_string(key)) <>
          "=" <> URI.encode_www_form(Kernel.to_string(value))
    end
  end
end
