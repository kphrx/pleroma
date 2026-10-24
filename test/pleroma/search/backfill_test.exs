# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.BackfillTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.Search.Backfill
  alias Pleroma.Workers.SearchIndexingWorker

  test "enqueues the exact requested number across partial pages" do
    activities = insert_list(5, :note_activity) |> Enum.sort_by(& &1.id, :desc)

    assert %{enqueued: 3, exhausted: false, next_cursor: cursor} =
             Backfill.run(limit: 3, step: 2, chunk: 2)

    assert search_indexing_ids() == Enum.map(Enum.take(activities, 3), & &1.id)
    assert cursor == Enum.at(activities, 2).id
  end

  test "resumes after the last processed activity without duplicates" do
    activities = insert_list(5, :note_activity) |> Enum.sort_by(& &1.id, :desc)

    assert %{enqueued: 2, next_cursor: cursor} = Backfill.run(limit: 2, step: 1)

    Pleroma.Repo.delete_all(Oban.Job)

    assert %{enqueued: 2, next_cursor: next_cursor} =
             Backfill.run(before: cursor, limit: 2, step: 1)

    assert search_indexing_ids() ==
             activities
             |> Enum.slice(2, 2)
             |> Enum.map(& &1.id)

    assert next_cursor == Enum.at(activities, 3).id
  end

  test "only queues Create activities" do
    create = insert(:note_activity)
    insert(:like_activity, note_activity: create)

    assert %{enqueued: 1, exhausted: true, next_cursor: cursor} = Backfill.run(step: 2)
    assert search_indexing_ids() == [create.id]
    assert cursor == create.id
  end

  test "rejects unknown options and malformed cursors before enqueueing" do
    assert_raise ArgumentError, fn -> Backfill.run(limt: 1) end
    assert_raise ArgumentError, fn -> Backfill.run(before: "not-an-activity-id") end
    assert_raise ArgumentError, fn -> Backfill.run(on_page: :invalid) end

    assert all_enqueued(worker: SearchIndexingWorker) == []
  end

  test "does not duplicate or skip the initial activities when newer rows are inserted" do
    activities = insert_list(3, :note_activity) |> Enum.sort_by(& &1.id, :desc)

    assert %{enqueued: 3, exhausted: true} =
             Backfill.run(
               limit: :infinity,
               step: 1,
               on_page: fn %{enqueued: enqueued} ->
                 if enqueued == 1, do: insert(:note_activity)
               end
             )

    assert search_indexing_ids() == Enum.map(activities, & &1.id)
  end

  defp search_indexing_ids do
    all_enqueued(worker: SearchIndexingWorker)
    |> Enum.sort_by(& &1.id)
    |> Enum.map(& &1.args["activity"])
  end
end
