# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTPTest do
  use ExUnit.Case, async: true
  use Pleroma.Tests.Helpers
  import Tesla.Mock
  alias Pleroma.HTTP

  setup do
    mock(fn
      %{
        method: :get,
        url: "http://example.com/hello",
        headers: [{"content-type", "application/json"}]
      } ->
        json(%{"my" => "data"})

      %{method: :head, url: "http://example.com/hello"} ->
        %Tesla.Env{status: 200, body: ""}

      %{method: :get, url: "http://example.com/hello"} ->
        %Tesla.Env{status: 200, body: "hello"}

      %{method: :post, url: "http://example.com/world"} ->
        %Tesla.Env{status: 200, body: "world"}

      %{method: :get, url: "https://example.com/emoji/Pack%201/koronebless.png?foo=bar+baz"} ->
        %Tesla.Env{status: 200, body: "emoji data"}

      %{
        method: :get,
        url: "https://example.com/media/foo/bar%20!$&'()*+,;=/:%20@a%20%5Bbaz%5D.mp4"
      } ->
        %Tesla.Env{status: 200, body: "video data"}

      %{method: :get, url: "https://example.com/media/unicode%20%F0%9F%99%82%20.gif"} ->
        %Tesla.Env{status: 200, body: "unicode data"}
    end)

    :ok
  end

  describe "head/1" do
    test "returns successfully result" do
      assert HTTP.head("http://example.com/hello") == {:ok, %Tesla.Env{status: 200, body: ""}}
    end
  end

  describe "get/1" do
    test "returns successfully result" do
      assert HTTP.get("http://example.com/hello") == {
               :ok,
               %Tesla.Env{status: 200, body: "hello"}
             }
    end
  end

  describe "get/2 (with headers)" do
    test "returns successfully result for json content-type" do
      assert HTTP.get("http://example.com/hello", [{"content-type", "application/json"}]) ==
               {
                 :ok,
                 %Tesla.Env{
                   status: 200,
                   body: "{\"my\":\"data\"}",
                   headers: [{"content-type", "application/json"}]
                 }
               }
    end
  end

  describe "post/2" do
    test "returns successfully result" do
      assert HTTP.post("http://example.com/world", "") == {
               :ok,
               %Tesla.Env{status: 200, body: "world"}
             }
    end
  end

  test "URL encoding properly encodes URLs with spaces" do
    clear_config(:test_url_encoding, true)

    url_with_space = "https://example.com/emoji/Pack 1/koronebless.png?foo=bar baz"

    {:ok, result} = HTTP.get(url_with_space)

    assert result.status == 200

    properly_encoded_url = "https://example.com/emoji/Pack%201/koronebless.png?foo=bar+baz"

    {:ok, result} = HTTP.get(properly_encoded_url)

    assert result.status == 200

    url_with_reserved_chars = "https://example.com/media/foo/bar !$&'()*+,;=/: @a [baz].mp4"

    {:ok, result} = HTTP.get(url_with_reserved_chars)

    assert result.status == 200

    url_with_unicode = "https://example.com/media/unicode 🙂 .gif"

    {:ok, result} = HTTP.get(url_with_unicode)

    assert result.status == 200
  end

  test "decodes URL first by default" do
    clear_config(:test_url_encoding, true)

    normal_url = "https://example.com/media/file%20with%20space.jpg?name=a+space.jpg"

    result = HTTP.encode_url(normal_url)

    assert result == "https://example.com/media/file%20with%20space.jpg?name=a+space.jpg"
  end

  test "doesn't decode URL first when specified" do
    clear_config(:test_url_encoding, true)

    normal_url = "https://example.com/media/file%20with%20space.jpg"

    result = HTTP.encode_url(normal_url, bypass_decode: true)

    assert result == "https://example.com/media/file%2520with%2520space.jpg"
  end
end
