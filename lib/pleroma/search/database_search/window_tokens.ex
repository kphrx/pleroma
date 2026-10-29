# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearch.WindowTokens do
  @bucket_size 10_000
  # More tokens than this in one query cost more than they save.
  @max_tokens 200

  @moduledoc """
  Optional window tokens in the `objects_fts` full-text index.

  With tokens, the index expression adds one lexeme per bucket of
  #{@bucket_size} object ids (`W0`, `W1`, ...) to the content's tsvector. A search
  for an id window then adds the window's tokens to the text query, so the
  GIN index itself returns only the matches inside the window, also when the
  planner underestimates the matches of a query with several words.

  The lexemes are upper case, and text search configurations lowercase every
  word, so they never collide with content. Changing the bucket size needs an
  index rebuild (`mix pleroma.database search_window_tokens enable`).
  """

  def bucket_size, do: @bucket_size

  @doc "SQL of the search expression; the parameters are regconfig oid, data and id."
  def vector_sql do
    "(to_tsvector(?::oid::regconfig, ?->>'content') || ('W' || (? / #{@bucket_size})::text)::tsvector)"
  end

  @doc "SQL of the index expression for the form and text search config."
  def index_expression(:plain, config),
    do: "to_tsvector(#{quote_config(config)}::regconfig, data->>'content')"

  def index_expression(:tokens, config) do
    "(to_tsvector(#{quote_config(config)}::regconfig, data->>'content') || " <>
      "('W' || (id / #{@bucket_size})::text)::tsvector)"
  end

  defp quote_config(config), do: "'" <> String.replace(config, "'", "''") <> "'"

  @doc "The form of the `objects_fts` index from its definition (`pg_indexes.indexdef`)."
  def form(nil), do: :missing

  def form(definition) do
    cond do
      definition =~ "USING rum" -> :rum
      # A partial index does not serve every search.
      definition =~ ") WHERE " -> :unknown
      definition =~ "('W'::text || ((id / #{@bucket_size}))::text)" -> :tokens
      definition =~ "'W'::text" -> :unknown
      definition =~ "to_tsvector(" -> :plain
      true -> :unknown
    end
  end

  @doc """
  Tsquery of the buckets that hold ids between `lower` and `upper` (both
  exclusive), newest first. `:empty` if there are no such ids, `:none` if the
  window is too wide for tokens.
  """
  def window(lower, upper) do
    first = lower + 1
    last = upper - 1

    if first > last,
      do: :empty,
      else: tokens(div(last, @bucket_size), div(first, @bucket_size), & &1)
  end

  @doc """
  Tsquery that excludes the buckets that only hold ids from `upper` up to
  `max_id`, for a search of all ids below `upper`. `:none` if there are no
  such buckets or too many.
  """
  def rest(upper, max_id) do
    newest = div(max_id, @bucket_size)
    oldest = div(upper + @bucket_size - 1, @bucket_size)

    if oldest > newest, do: :none, else: tokens(newest, oldest, &"!(#{&1})")
  end

  defp tokens(newest, oldest, _wrap) when newest - oldest + 1 > @max_tokens, do: :none

  defp tokens(newest, oldest, wrap),
    do: {:tokens, wrap.(Enum.map_join(newest..oldest//-1, " | ", &"W#{&1}"))}
end
