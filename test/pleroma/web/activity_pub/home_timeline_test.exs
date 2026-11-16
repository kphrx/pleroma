# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.HomeTimelineTest do
  use Pleroma.DataCase

  import Mock
  require Pleroma.Constants
  import Pleroma.Factory

  alias Pleroma.Pagination
  alias Pleroma.Web.ActivityPub.ActivityPub

  defp setting(name), do: Repo.query!("SELECT current_setting($1)", [name]).rows |> hd() |> hd()

  describe "exact home timeline queries" do
    test "uses exact GIN only for home selection and restores the caller's setting" do
      user = insert(:user)
      Repo.query!("SET LOCAL gin_fuzzy_search_limit = 321")

      with_mock Pagination, [:passthrough],
        fetch_paginated: fn _query, _opts, :keyset, nil ->
          send(self(), {:gin_limit, setting("gin_fuzzy_search_limit")})
          []
        end do
        assert ActivityPub.fetch_home_activities([user.ap_id], %{user: user}) == []
        assert_received {:gin_limit, "0"}
        assert setting("gin_fuzzy_search_limit") == "321"

        assert ActivityPub.fetch_activities([user.ap_id], %{user: user}) == []
        assert_received {:gin_limit, "321"}
      end
    end

    test "restores settings inside an existing transaction" do
      user = insert(:user)

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL gin_fuzzy_search_limit = 123")
                 ActivityPub.fetch_home_activities([user.ap_id], %{user: user})
                 assert setting("gin_fuzzy_search_limit") == "123"
                 :ok
               end)
    end

    test "restores the caller's transaction after a database error" do
      user = insert(:user)
      Repo.query!("SET LOCAL gin_fuzzy_search_limit = 123")

      with_mock Pagination, [:passthrough],
        fetch_paginated: fn _query, _opts, :keyset, nil ->
          Repo.query!("SELECT 1 / 0")
        end do
        assert_raise Postgrex.Error, fn ->
          ActivityPub.fetch_home_activities([user.ap_id], %{user: user})
        end
      end

      assert setting("gin_fuzzy_search_limit") == "123"
      assert Repo.query!("SELECT 1").rows == [[1]]
    end
  end

  describe "bounded fast selection" do
    setup do
      user = insert(:user)
      recipients = [user.ap_id | Enum.map(1..127, &"https://example.org/followers/#{&1}")]
      opts = %{user: user, type: ["Create", "Announce"], limit: 2}
      %{user: user, recipients: recipients, opts: opts}
    end

    test "gates on unique recipients and excludes followed hashtags", ctx do
      for {recipients, opts} <- [
            {Enum.take(ctx.recipients, 127), ctx.opts},
            {List.duplicate(ctx.user.ap_id, 128), ctx.opts},
            {ctx.recipients, Map.put(ctx.opts, :followed_hashtags, [123])}
          ] do
        {[], queries} = queries(fn -> ActivityPub.fetch_home_activities(recipients, opts) end)
        refute fast?(queries)
      end

      {[], queries} =
        queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, ctx.opts) end)

      assert fast?(queries)
      refute fallback?(queries)
    end

    test "returns a full page with self posts, recipient posts, and preloaded objects", ctx do
      own = insert(:note_activity, user: ctx.user)

      addressed =
        insert(:note_activity,
          recipients: [ctx.user.ap_id],
          data_attrs: %{"to" => [ctx.user.ap_id]}
        )

      insert(:note_activity)

      {activities, queries} =
        queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, ctx.opts) end)

      assert Enum.map(activities, & &1.id) == [own.id, addressed.id]
      assert Enum.all?(activities, &Ecto.assoc_loaded?(&1.object))
      assert fast?(queries)
      refute fallback?(queries)
    end

    test "returns exhausted partial and empty polling pages without fallback", ctx do
      old = insert(:note_activity, user: ctx.user)
      newest = insert(:note_activity, user: ctx.user)

      for {since_id, expected} <- [{old.id, [newest.id]}, {newest.id, []}] do
        {activities, queries} =
          queries(fn ->
            ActivityPub.fetch_home_activities(
              ctx.recipients,
              Map.put(ctx.opts, :since_id, since_id)
            )
          end)

        assert Enum.map(activities, & &1.id) == expected
        assert fast?(queries)
        refute fallback?(queries)
      end
    end

    test "falls back when sparse matches lie beyond the candidate window", ctx do
      old = insert(:note_activity, user: ctx.user)
      insert_gap(8192, ctx.user)
      newest = insert(:note_activity, user: ctx.user)

      {activities, queries} =
        queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, ctx.opts) end)

      assert Enum.map(activities, & &1.id) == [old.id, newest.id]
      assert fast?(queries)
      assert fallback?(queries)
    end

    test "distinguishes exactly 8192 candidates from a truncated empty window", ctx do
      old = insert(:note_activity, user: ctx.user)
      insert_gap(8191, ctx.user)

      {activities, first_queries} =
        queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, ctx.opts) end)

      assert Enum.map(activities, & &1.id) == [old.id]
      assert fast?(first_queries)
      refute fallback?(first_queries)

      insert_gap(1, ctx.user)

      {activities, second_queries} =
        queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, ctx.opts) end)

      assert Enum.map(activities, & &1.id) == [old.id]
      assert fast?(second_queries)
      assert fallback?(second_queries)
    end

    test "applies min, max and since bounds before bounding candidates", ctx do
      oldest = insert(:note_activity, user: ctx.user)
      middle = insert(:note_activity, user: ctx.user)
      newest = insert(:note_activity, user: ctx.user)
      insert_gap(8193, ctx.user)

      for bounds <- [
            %{max_id: newest.id},
            %{min_id: oldest.id, max_id: newest.id},
            %{since_id: oldest.id, max_id: newest.id},
            %{min_id: oldest.id, limit: "1"},
            %{min_id: middle.id, order_asc: true, limit: 1}
          ] do
        opts = Map.merge(ctx.opts, bounds)
        expected = ActivityPub.fetch_activities(ctx.recipients, opts) |> Enum.map(& &1.id)

        {activities, queries} =
          queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, opts) end)

        assert Enum.map(activities, & &1.id) == expected
        assert fast?(queries)
        refute fallback?(queries)
      end
    end

    test "preserves block, mute, media, locality and visibility filters", ctx do
      author = insert(:user)
      muted = insert(:user)
      blocked = insert(:user)
      Pleroma.User.mute(ctx.user, muted)
      Pleroma.User.block(ctx.user, blocked)

      for user <- [author, muted, blocked] do
        insert(:note_activity,
          user: user,
          recipients: [ctx.user.ap_id],
          data_attrs: %{"to" => [ctx.user.ap_id]}
        )
      end

      insert(:note_activity, user: ctx.user, local: false)
      insert(:note_activity, user: ctx.user)

      media =
        insert(:note_activity,
          user: ctx.user,
          note:
            insert(:note,
              user: ctx.user,
              data: %{
                "attachment" => [%{"type" => "Image", "url" => "https://example.org/image.png"}]
              }
            )
        )

      {:ok, _bookmark} = Pleroma.Bookmark.create(ctx.user.id, media.id)

      for filters <- [
            %{},
            %{with_muted: true},
            %{local_only: true},
            %{remote: true},
            %{only_media: true},
            %{exclude_visibilities: ["public"]}
          ] do
        opts =
          Map.merge(
            ctx.opts,
            Map.merge(%{blocking_user: ctx.user, muting_user: ctx.user, limit: 40}, filters)
          )

        expected = ActivityPub.fetch_activities(ctx.recipients, opts)

        {activities, queries} =
          queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, opts) end)

        assert activities == expected
        assert fast?(queries)
        refute fallback?(queries)
      end
    end

    test "preserves reply filtering and the virtual thread mute field", ctx do
      parent = insert(:note_activity, user: ctx.user)

      reply =
        insert(:note_activity,
          user: ctx.user,
          note: insert(:note, user: ctx.user, data: %{"inReplyTo" => parent.data["object"]})
        )

      {:ok, _} = Pleroma.ThreadMute.add_mute(ctx.user.id, reply.data["context"])

      opts =
        Map.merge(ctx.opts, %{
          with_muted: true,
          muting_user: ctx.user,
          reply_filtering_user: ctx.user
        })

      for filters <- [
            %{},
            %{reply_visibility: "self"},
            %{reply_visibility: "following"},
            %{exclude_replies: true}
          ] do
        opts = Map.merge(opts, filters)
        expected = ActivityPub.fetch_activities(ctx.recipients, opts)

        {activities, queries} =
          queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, opts) end)

        assert activities == expected
        assert fast?(queries)
        refute fallback?(queries)
      end

      activities = ActivityPub.fetch_home_activities(ctx.recipients, opts)
      assert Enum.find(activities, &(&1.id == reply.id)).thread_muted?
    end

    test "includes list memberships in the gate and preserves list bcc postprocessing", ctx do
      owner = insert(:user)
      {:ok, list} = Pleroma.List.create(%{title: "members"}, owner)
      {:ok, list} = Pleroma.List.follow(list, ctx.user)

      activity =
        insert(:note_activity,
          user: owner,
          recipients: [list.ap_id, Pleroma.Constants.as_public()],
          data_attrs: %{"bcc" => [list.ap_id], "cc" => [], "to" => [ctx.user.ap_id]}
        )

      recipients = Enum.take(ctx.recipients, 127)

      {activities, queries} =
        queries(fn -> ActivityPub.fetch_home_activities(recipients, ctx.opts) end)

      assert [result] = activities
      assert result.id == activity.id
      assert result.data["cc"] == [ctx.user.ap_id]
      assert fast?(queries)
      refute fallback?(queries)
    end

    test "uses the configured default and maximum page sizes", ctx do
      for _ <- 1..41, do: insert(:note_activity, user: ctx.user)

      for opts <- [Map.delete(ctx.opts, :limit), Map.put(ctx.opts, :limit, "100")] do
        expected = ActivityPub.fetch_activities(ctx.recipients, opts)

        {activities, queries} =
          queries(fn -> ActivityPub.fetch_home_activities(ctx.recipients, opts) end)

        assert activities == expected
        assert fast?(queries)
        refute fallback?(queries)
      end
    end

    test "does not swallow non-cancellation errors in the fast query", ctx do
      Repo.query!("SET LOCAL gin_fuzzy_search_limit = 123")
      Repo.query!("SET LOCAL statement_timeout = '5s'")

      with_mock Repo, [:passthrough],
        all: fn query ->
          {sql, _} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

          if String.contains?(sql, "home_timeline_candidates"),
            do: Repo.query!("SELECT 1 / 0"),
            else: :meck.passthrough([query])
        end do
        error =
          assert_raise Postgrex.Error, fn ->
            ActivityPub.fetch_home_activities(ctx.recipients, ctx.opts)
          end

        assert error.postgres.code == :division_by_zero
      end

      assert setting("statement_timeout") == "5s"
      assert setting("gin_fuzzy_search_limit") == "123"
    end

    test "also recovers when bounded hydration times out", ctx do
      activity = insert(:note_activity, user: ctx.user)

      with_mock Repo, [:passthrough],
        all: fn query ->
          {sql, _} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

          if String.contains?(sql, "unnest(") and
               not String.contains?(sql, "home_timeline_candidates") do
            send(self(), :hydration_timeout)
            Repo.query!("SELECT pg_sleep(1)")
          else
            :meck.passthrough([query])
          end
        end do
        assert [result] = ActivityPub.fetch_home_activities(ctx.recipients, ctx.opts)
        assert result.id == activity.id
        assert_received :hydration_timeout
      end
    end

    test "recovers from a real statement timeout and restores both settings", ctx do
      activity = insert(:note_activity, user: ctx.user)
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      Repo.query!("SET LOCAL gin_fuzzy_search_limit = 123")

      with_mock Repo, [:passthrough],
        all: fn query ->
          {sql, _} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

          if String.contains?(sql, "home_timeline_candidates") do
            assert setting("gin_fuzzy_search_limit") == "0"
            send(self(), :timed_fast_query)
            Repo.query!("SELECT pg_sleep(1)")
          else
            result = :meck.passthrough([query])

            if String.contains?(sql, " && ") do
              assert setting("gin_fuzzy_search_limit") == "0"
              assert setting("statement_timeout") == "5s"
            end

            result
          end
        end do
        assert [result] = ActivityPub.fetch_home_activities(ctx.recipients, ctx.opts)
        assert result.id == activity.id
        assert_received :timed_fast_query
      end

      assert setting("statement_timeout") == "5s"
      assert setting("gin_fuzzy_search_limit") == "123"
      assert Repo.query!("SELECT 1").rows == [[1]]
    end
  end

  defp insert_gap(count, user) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for _ <- 1..count,
          do: %{
            id: FlakeId.get(),
            actor: user.ap_id,
            recipients: [],
            data: %{"type" => "Like"},
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(Pleroma.Activity, rows)
  end

  defp queries(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:pleroma, :repo, :query], &__MODULE__.record_query/4, self())

    try do
      result = fun.()
      {result, drain_queries()}
    after
      :telemetry.detach(id)
    end
  end

  def record_query(_event, _measurements, metadata, pid), do: send(pid, {:query, metadata.query})

  defp drain_queries do
    receive do
      {:query, query} -> [query | drain_queries()]
    after
      0 -> []
    end
  end

  defp fast?(queries), do: Enum.any?(queries, &String.contains?(&1, "home_timeline_candidates"))

  defp fallback?(queries),
    do:
      Enum.any?(queries, &(String.contains?(&1, " && ") and not String.contains?(&1, "unnest(")))
end
