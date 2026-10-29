# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.DatabaseSearch.WindowTokensTest do
  use ExUnit.Case, async: true

  alias Pleroma.Search.DatabaseSearch.WindowTokens

  describe "window/2" do
    test "returns the buckets of the ids between the bounds, newest first" do
      # ids 15_001..25_000
      assert WindowTokens.window(15_000, 25_001) == {:tokens, "W2 | W1"}
    end

    test "uses one bucket when the window fits into it" do
      assert WindowTokens.window(20_000, 30_000) == {:tokens, "W2"}
      assert WindowTokens.window(19_999, 20_001) == {:tokens, "W2"}
    end

    test "covers the bucket boundaries exactly" do
      # ids 9_999 and 10_000
      assert WindowTokens.window(9_998, 10_001) == {:tokens, "W1 | W0"}
    end

    test "is empty when no id is between the bounds" do
      assert WindowTokens.window(9_999, 10_000) == :empty
    end

    test "does not use tokens for very wide windows" do
      assert WindowTokens.window(0, 10_000 * 500) == :none
    end
  end

  describe "rest/2" do
    test "excludes the buckets that only hold newer ids" do
      # ids below 25_001; buckets 3 and 4 only hold ids from 30_000
      assert WindowTokens.rest(25_001, 40_000) == {:tokens, "!(W4 | W3)"}
    end

    test "keeps a bucket that also holds older ids" do
      assert WindowTokens.rest(30_001, 39_999) == :none
      assert WindowTokens.rest(30_000, 39_999) == {:tokens, "!(W3)"}
    end

    test "does not use tokens when too many buckets would be excluded" do
      assert WindowTokens.rest(1, 10_000 * 500) == :none
    end
  end

  describe "form/1" do
    test "detects the token index" do
      definition =
        "CREATE INDEX objects_fts ON public.objects USING gin (((to_tsvector('english'::regconfig, (data ->> 'content'::text)) || (('W'::text || ((id / 10000))::text))::tsvector)))"

      assert WindowTokens.form(definition) == :tokens
    end

    test "detects the plain index" do
      definition =
        "CREATE INDEX objects_fts ON public.objects USING gin (to_tsvector('english'::regconfig, (data ->> 'content'::text)))"

      assert WindowTokens.form(definition) == :plain
    end

    test "detects partial indexes as unknown" do
      assert WindowTokens.form(
               "CREATE INDEX objects_fts ON public.objects USING gin (to_tsvector('english'::regconfig, (data ->> 'content'::text))) WHERE (id > 0)"
             ) == :unknown
    end

    test "detects RUM, missing and unknown indexes" do
      assert WindowTokens.form(
               "CREATE INDEX objects_fts ON public.objects USING rum (fts_content rum_tsvector_addon_ops, inserted_at)"
             ) == :rum

      assert WindowTokens.form(nil) == :missing

      # Tokens with another bucket size do not match the search expression.
      assert WindowTokens.form(
               "CREATE INDEX objects_fts ON public.objects USING gin (((to_tsvector('english'::regconfig, (data ->> 'content'::text)) || (('W'::text || ((id / 100000))::text))::tsvector)))"
             ) == :unknown
    end
  end

  test "index_expression/2 builds the expressions for a text search config" do
    assert WindowTokens.index_expression(:plain, "english") ==
             "to_tsvector('english'::regconfig, data->>'content')"

    assert WindowTokens.index_expression(:tokens, "pg_catalog.english") ==
             "(to_tsvector('pg_catalog.english'::regconfig, data->>'content') || ('W' || (id / 10000)::text)::tsvector)"
  end
end
