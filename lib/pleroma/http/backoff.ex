# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.Backoff do
  @moduledoc """
  GET wrapper that stops sending requests to a host after it answers
  429 or 503, until the time given by `Retry-After` or `X-RateLimit-Reset`.

  Based on Akkoma's `Pleroma.HTTP.Backoff`.
  """

  alias Pleroma.HTTP

  require Logger

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @cache :http_backoff_cache

  @default_seconds 5 * 60
  @max_seconds 60 * 60

  @spec get(String.t(), list(), keyword()) :: {:ok, Tesla.Env.t()} | {:error, any()}
  def get(url, headers \\ [], options \\ []) when is_binary(url) do
    host = URI.parse(url).host

    case @cachex.get(@cache, host) do
      {:ok, true} ->
        {:error, :ratelimit}

      _ ->
        url
        |> HTTP.get(headers, options)
        |> check_backoff(host)
    end
  end

  defp check_backoff({:ok, %{status: status, headers: headers}}, host)
       when status in [429, 503] do
    seconds = backoff_seconds(headers, DateTime.utc_now())
    Logger.warning("#{host} answered #{status}, backing off for #{seconds} seconds")
    @cachex.put(@cache, host, true, ttl: :timer.seconds(seconds))
    {:error, :ratelimit}
  end

  defp check_backoff(response, _host), do: response

  @doc """
  Seconds to back off for, from the first valid `Retry-After` or
  `X-RateLimit-Reset` header. Missing, invalid or past values give the
  default of #{@default_seconds} seconds; values are capped at #{@max_seconds}.
  """
  @spec backoff_seconds(list(), DateTime.t()) :: pos_integer()
  def backoff_seconds(headers, now) do
    [
      parse_retry_after(header(headers, "retry-after"), now),
      parse_timestamp(header(headers, "x-ratelimit-reset"), now)
    ]
    |> Enum.find(@default_seconds, &is_integer/1)
    |> min(@max_seconds)
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: String.trim(value)

      _ ->
        nil
    end)
  end

  # Retry-After is either delta-seconds or an HTTP-date (RFC 9110, 10.2.3)
  defp parse_retry_after(nil, _now), do: nil

  defp parse_retry_after(value, now) do
    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 -> seconds
      {_, ""} -> nil
      _ -> parse_timestamp(value, now)
    end
  end

  defp parse_timestamp(nil, _now), do: nil

  defp parse_timestamp(value, now) do
    with {:ok, %DateTime{} = datetime} <- parse_datetime(value),
         seconds when seconds > 0 <- DateTime.diff(datetime, now) do
      seconds
    else
      _ -> nil
    end
  end

  defp parse_datetime(value) do
    with {:error, _} <- Timex.parse(value, "{RFC1123}"),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    end
  end
end
