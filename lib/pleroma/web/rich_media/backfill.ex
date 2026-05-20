# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RichMedia.Backfill do
  alias Pleroma.Web.RichMedia.Card
  alias Pleroma.Web.RichMedia.Helpers
  alias Pleroma.Web.RichMedia.Parser
  alias Pleroma.Web.RichMedia.Parser.TTL
  alias Pleroma.Workers.RichMediaWorker

  require Logger

  @callback run(map()) :: :ok | Parser.parse_errors() | Helpers.get_errors()

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @stream_out_impl Pleroma.Config.get(
                     [__MODULE__, :stream_out],
                     Pleroma.Web.ActivityPub.ActivityPub
                   )

  @spec run(map()) :: :ok | Parser.parse_errors() | Helpers.get_errors()
  def run(%{"url" => url} = args) do
    url_hash = Card.url_to_hash(url)

    case Parser.parse(url) do
      {:ok, fields} ->
        {:ok, card} = Card.create(url, fields)

        maybe_schedule_expiration(url, fields)
        maybe_update_stream(args)

        warm_cache(url_hash, card)
        :ok

      {:error, type} = error
      when type in [:invalid_metadata, :body_too_large, :content_type, :validate, :get, :head] ->
        negative_cache(url_hash)
        error
    end
  end

  defp maybe_schedule_expiration(url, fields) do
    case TTL.process(fields, url) do
      {:ok, ttl} when is_number(ttl) ->
        timestamp = DateTime.from_unix!(ttl)

        RichMediaWorker.new(%{"op" => "expire", "url" => url}, scheduled_at: timestamp)
        |> Oban.insert()

      _ ->
        :ok
    end
  end

  defp maybe_update_stream(%{"activity_id" => activity_id, "stream" => true}) when is_binary(activity_id) do
    Pleroma.Activity.get_by_id(activity_id)
    |> Pleroma.Activity.normalize()
    |> @stream_out_impl.stream_out()
  end

  # Streamer.stream_out returns noop when unsupported activity type is requested to be streamed.
  # Do the same here for unwanted streaming
  defp maybe_update_stream(_), do: :noop

  defp warm_cache(key, val), do: @cachex.put(:rich_media_cache, key, val)

  defp negative_cache(key, ttl \\ :timer.minutes(15)),
    do: @cachex.put(:rich_media_cache, key, :error, ttl: ttl)
end
