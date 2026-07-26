# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Mix.Tasks.Pleroma.Search.Indexer do
  import Mix.Pleroma

  def run(["create_index"]) do
    start_pleroma()

    with :ok <- Pleroma.Config.get([Pleroma.Search, :module]).create_index() do
      IO.puts("Index created")
    else
      e -> IO.puts("Could not create index: #{inspect(e)}")
    end
  end

  def run(["drop_index"]) do
    start_pleroma()

    with :ok <- Pleroma.Config.get([Pleroma.Search, :module]).drop_index() do
      IO.puts("Index dropped")
    else
      e -> IO.puts("Could not drop index: #{inspect(e)}")
    end
  end

  def run(["index" | options]) do
    {options, [], []} =
      OptionParser.parse(
        options,
        strict: [
          chunk: :integer,
          limit: :integer,
          step: :integer,
          before: :string
        ]
      )

    start_pleroma()

    result =
      Pleroma.Search.Backfill.run(
        options ++
          [
            on_page: fn page ->
              IO.puts(
                "Queued #{page.count} activities (#{page.enqueued} total), " <>
                  "checkpoint: #{page.next_cursor}"
              )
            end
          ]
      )

    IO.puts("Queued #{result.enqueued} activities")

    unless result.exhausted do
      IO.puts("Resume with --before #{result.next_cursor}")
    end
  end
end
