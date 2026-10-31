# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# Based on Akkoma's test/pleroma/http/backoff_test.exs
defmodule Pleroma.HTTP.BackoffTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.HTTP.Backoff

  @cache :http_backoff_cache
  @url "https://ratelimited.example.com/users/alice"
  @host "ratelimited.example.com"

  defp mock_response(status, headers \\ []) do
    test_pid = self()

    Tesla.Mock.mock(fn %{method: :get} ->
      send(test_pid, :request)
      %Tesla.Env{status: status, headers: headers, body: ""}
    end)
  end

  defp ttl_seconds do
    {:ok, ttl} = Cachex.ttl(@cache, @host)
    div(ttl, 1000)
  end

  defp assert_ttl_about(expected) do
    ttl = ttl_seconds()
    assert ttl in (expected - 15)..expected//1, "expected a TTL near #{expected}, got #{ttl}"
  end

  describe "get/3" do
    test "returns the response when the host is not backed off" do
      mock_response(200)

      assert {:ok, %Tesla.Env{status: 200}} = Backoff.get(@url)
      assert {:ok, nil} = Cachex.get(@cache, @host)
    end

    test "does not send a request while the host is backed off" do
      Cachex.put(@cache, @host, true)
      mock_response(200)

      assert {:error, :ratelimit} = Backoff.get(@url)
      refute_received :request
    end

    for status <- [429, 503] do
      test "backs off from the host after a #{status} response" do
        mock_response(unquote(status))

        assert {:error, :ratelimit} = Backoff.get(@url)
        assert_received :request
        assert {:ok, true} = Cachex.get(@cache, @host)

        assert {:error, :ratelimit} = Backoff.get(@url <> "/other")
        refute_received :request
      end
    end

    test "uses a default backoff without headers" do
      mock_response(429)

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(300)
    end

    test "only backs off from the host that answered" do
      mock_response(429)
      assert {:error, :ratelimit} = Backoff.get(@url)

      mock_response(200)
      assert {:ok, _} = Backoff.get("https://other.example.com/users/bob")
    end
  end

  describe "backoff headers" do
    test "parses Retry-After in seconds" do
      mock_response(429, [{"retry-after", "600"}])

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(600)
    end

    test "parses Retry-After as an HTTP-date" do
      date =
        DateTime.utc_now()
        |> DateTime.add(600)
        |> Timex.format!("{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT")

      mock_response(503, [{"retry-after", date}])

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(600)
    end

    test "parses Retry-After as an ISO 8601 timestamp" do
      date = DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601()
      mock_response(429, [{"retry-after", date}])

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(600)
    end

    test "parses X-RateLimit-Reset as an ISO 8601 timestamp" do
      date = DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601()
      mock_response(429, [{"x-ratelimit-reset", date}])

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(600)
    end

    test "matches header names case-insensitively" do
      mock_response(429, [{"Retry-After", "600"}])

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(600)
    end

    test "prefers Retry-After over X-RateLimit-Reset" do
      date = DateTime.utc_now() |> DateTime.add(1200) |> DateTime.to_iso8601()
      mock_response(429, [{"x-ratelimit-reset", date}, {"retry-after", "600"}])

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(600)
    end

    test "falls back to the next header when one is invalid" do
      date = DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601()
      mock_response(429, [{"retry-after", "soon"}, {"x-ratelimit-reset", date}])

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(600)
    end

    for value <- ["soon", "-5", "0", "12.5", "", "Wed, 21 Oct 2015 07:28:00 GMT"] do
      test "ignores the invalid or past Retry-After value #{inspect(value)}" do
        mock_response(429, [{"retry-after", unquote(value)}])

        assert {:error, :ratelimit} = Backoff.get(@url)
        assert_ttl_about(300)
      end
    end

    test "caps absurd values at one hour" do
      mock_response(429, [{"retry-after", "99999999999"}])

      assert {:error, :ratelimit} = Backoff.get(@url)
      assert_ttl_about(3600)
    end
  end
end
