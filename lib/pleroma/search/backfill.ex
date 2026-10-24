# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.Backfill do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Workers.SearchIndexingWorker

  @default_chunk_size 100
  @default_step_size 1_000
  @default_limit 100_000

  @doc """
  Enqueues existing Create activities for search indexing.

  The returned `next_cursor` can be passed as `before` to resume a bounded run.
  Pass `limit: :infinity` to continue until the oldest activity is reached.
  """
  def run(options \\ []) do
    options =
      Keyword.validate!(options,
        chunk: @default_chunk_size,
        step: @default_step_size,
        limit: @default_limit,
        before: nil,
        on_page: nil
      )

    chunk_size = positive_option!(options, :chunk, @default_chunk_size)
    step_size = positive_option!(options, :step, @default_step_size)
    limit = limit_option!(options)
    before = cursor_option!(options[:before])
    on_page = callback_option!(options[:on_page])

    do_run(before, limit, step_size, chunk_size, on_page, 0)
  end

  defp do_run(before, remaining, step_size, chunk_size, on_page, enqueued) do
    page_size = page_size(remaining, step_size)
    ids = fetch_ids(before, page_size)

    case ids do
      [] ->
        result(enqueued, before, true)

      ids ->
        enqueue(ids, chunk_size)

        page_count = length(ids)
        next_cursor = List.last(ids)
        total = enqueued + page_count
        remaining = decrement(remaining, page_count)

        on_page.(%{count: page_count, enqueued: total, next_cursor: next_cursor})

        cond do
          remaining == 0 -> result(total, next_cursor, false)
          page_count < page_size -> result(total, next_cursor, true)
          true -> do_run(next_cursor, remaining, step_size, chunk_size, on_page, total)
        end
    end
  end

  defp fetch_ids(before, limit) do
    Activity
    |> where([a], fragment("?->>'type' = 'Create'", a.data))
    |> maybe_before(before)
    |> order_by([a], desc: a.id)
    |> limit(^limit)
    |> select([a], a.id)
    |> Pleroma.Repo.all()
  end

  defp maybe_before(query, nil), do: query
  defp maybe_before(query, before), do: where(query, [a], a.id < ^before)

  defp enqueue(ids, chunk_size) do
    ids
    |> Enum.chunk_every(chunk_size)
    |> Enum.each(fn chunk ->
      chunk
      |> Enum.map(&SearchIndexingWorker.new(%{"op" => "add_to_index", "activity" => &1}))
      |> Oban.insert_all()
    end)
  end

  defp page_size(:infinity, step_size), do: step_size
  defp page_size(remaining, step_size), do: min(remaining, step_size)

  defp decrement(:infinity, _count), do: :infinity
  defp decrement(remaining, count), do: remaining - count

  defp result(enqueued, next_cursor, exhausted) do
    %{enqueued: enqueued, next_cursor: next_cursor, exhausted: exhausted}
  end

  defp positive_option!(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp limit_option!(options) do
    case Keyword.fetch!(options, :limit) do
      :infinity -> :infinity
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "limit must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp cursor_option!(nil), do: nil

  defp cursor_option!(cursor) do
    valid? =
      try do
        match?({:ok, <<_::binary-size(16)>>}, FlakeId.Ecto.CompatType.dump(cursor))
      rescue
        _ -> false
      end

    if valid? do
      cursor
    else
      raise ArgumentError, "before must be a valid activity id, got: #{inspect(cursor)}"
    end
  end

  defp callback_option!(nil), do: fn _ -> :ok end
  defp callback_option!(callback) when is_function(callback, 1), do: callback

  defp callback_option!(callback) do
    raise ArgumentError, "on_page must be a function of arity 1, got: #{inspect(callback)}"
  end
end
