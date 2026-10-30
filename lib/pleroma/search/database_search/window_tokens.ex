# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearch.WindowTokens do
  # Prefix and bucket size of each token level, narrowest first.
  @levels [{"W", 10_000}, {"X", 100_000}, {"Y", 1_000_000}]
  # More tokens than this in one query cost more than they save.
  @max_tokens 200

  @moduledoc """
  Optional window tokens in the `objects_fts` full-text index.

  With tokens, the index expression adds three lexemes to the content's
  tsvector: the object's bucket of 10_000 ids (`W0`, `W1`, ...), of 100_000
  ids (`X0`, ...) and of 1_000_000 ids (`Y0`, ...). A search for an id window
  adds the tokens of the level that is as wide as the window to the text
  query, so the GIN index itself returns only the matches inside the window.

  GIN starts a scan from the entries with the fewest matches. As a window's
  tokens hold about as many ids as the window, it starts from a rare word
  when the word is rarer than the window, and from the tokens otherwise.

  The lexemes are upper case, and text search configurations lowercase every
  word, so they never collide with content. Changing the levels needs an
  index rebuild (`mix pleroma.database search_window_tokens enable`).
  """

  @doc "Number of token levels; the search expression takes the id once per level."
  def level_count, do: length(@levels)

  @doc "Bucket size of the narrowest level."
  def bucket_size, do: @levels |> hd() |> elem(1)

  @doc "SQL of the search expression; the parameters are regconfig oid, data and the id once per level."
  def vector_sql,
    do: "(to_tsvector(?::oid::regconfig, ?->>'content') || (#{tokens_sql("?")})::tsvector)"

  @doc "SQL of the index expression for the form and text search config."
  def index_expression(:plain, config),
    do: "to_tsvector(#{quote_config(config)}::regconfig, data->>'content')"

  def index_expression(:tokens, config) do
    "(to_tsvector(#{quote_config(config)}::regconfig, data->>'content') || " <>
      "(#{tokens_sql("id")})::tsvector)"
  end

  # The same text for the index and the search, or PostgreSQL does not use the index:
  # 'W' || (id / 10000)::text || ' X' || (id / 100000)::text || ...
  defp tokens_sql(id) do
    @levels
    |> Enum.with_index()
    |> Enum.map_join(" || ", fn {{prefix, size}, index} ->
      separator = if index == 0, do: "", else: " "
      "'#{separator}#{prefix}' || (#{id} / #{size})::text"
    end)
  end

  defp quote_config(config), do: "'" <> String.replace(config, "'", "''") <> "'"

  @doc "The form of the `objects_fts` index from its definition (`pg_indexes.indexdef`)."
  def form(nil), do: :missing

  def form(definition) do
    cond do
      definition =~ "USING rum" -> :rum
      # A partial index does not serve every search.
      definition =~ ") WHERE " -> :unknown
      definition =~ definition_tokens() -> :tokens
      # Other tokens (an earlier form) do not match the search expression.
      definition =~ "'W'::text" -> :unknown
      definition =~ "to_tsvector(" -> :plain
      true -> :unknown
    end
  end

  @doc """
  Tsquery of the buckets that hold ids between `lower` and `upper` (both
  exclusive), newest first, from the narrowest level whose buckets are as
  wide as the window. `:empty` if there are no such ids, `:none` if the window
  is too wide for tokens.
  """
  def window(lower, upper) do
    first = lower + 1
    last = upper - 1

    if first > last do
      :empty
    else
      {prefix, size} = level(last - first + 1)
      tokens(prefix, div(last, size), div(first, size), & &1)
    end
  end

  @doc """
  Tsquery that excludes the widest buckets that only hold ids from `upper` up
  to `max_id`, for a search of all ids below `upper`. `:none` if there are no
  such buckets or too many.
  """
  def rest(upper, max_id) do
    {prefix, size} = List.last(@levels)
    newest = div(max_id, size)
    oldest = div(upper + size - 1, size)

    if oldest > newest, do: :none, else: tokens(prefix, newest, oldest, &"!(#{&1})")
  end

  # The token part of the expression as pg_get_indexdef shows it, up to the cast.
  defp definition_tokens do
    [{first, first_size} | rest] = @levels
    start = "('#{first}'::text || ((id / #{first_size}))::text)"

    Enum.reduce(rest, start, fn {prefix, size}, acc ->
      "((#{acc} || ' #{prefix}'::text) || ((id / #{size}))::text)"
    end) <> ")::tsvector"
  end

  defp level(ids), do: Enum.find(@levels, List.last(@levels), fn {_, size} -> size >= ids end)

  defp tokens(_prefix, newest, oldest, _wrap) when newest - oldest + 1 > @max_tokens, do: :none

  defp tokens(prefix, newest, oldest, wrap),
    do: {:tokens, wrap.(Enum.map_join(newest..oldest//-1, " | ", &"#{prefix}#{&1}"))}
end
