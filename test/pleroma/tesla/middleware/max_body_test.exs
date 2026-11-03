# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Tesla.Middleware.MaxBodyTest do
  use ExUnit.Case, async: true

  alias Pleroma.Tesla.Middleware.MaxBody

  defp client(adapter_opts, response) do
    Tesla.client([{MaxBody, nil}], fn env ->
      {:ok, %{env | status: 200, headers: response.headers, body: response.body}}
    end)
    |> then(fn c -> {c, [opts: [adapter: adapter_opts]]} end)
  end

  defp get(adapter_opts, response) do
    {c, opts} = client(adapter_opts, response)
    Tesla.get(c, "http://example.com/", opts)
  end

  test "passes a body within the limit through untouched" do
    assert {:ok, %Tesla.Env{status: 200, body: "hello"}} =
             get([max_body: 100], %{headers: [], body: "hello"})
  end

  test "rejects a body larger than the limit" do
    assert {:error, :body_too_large} =
             get([max_body: 4], %{headers: [], body: "hello"})
  end

  test "rejects when content-length exceeds the limit" do
    assert {:error, :body_too_large} =
             get([max_body: 4], %{headers: [{"content-length", "1000"}], body: ""})
  end

  test "allows a content-length equal to the limit" do
    assert {:ok, %Tesla.Env{status: 200}} =
             get([max_body: 5], %{headers: [{"content-length", "5"}], body: "hello"})
  end

  test "ignores an unparsable content-length" do
    assert {:ok, %Tesla.Env{status: 200}} =
             get([max_body: 100], %{headers: [{"content-length", "banana"}], body: "hi"})
  end

  test "does nothing without a max_body option" do
    big = String.duplicate("x", 10_000)

    assert {:ok, %Tesla.Env{body: ^big}} =
             get([], %{headers: [{"content-length", "10000"}], body: big})
  end

  # body_as: :chunks hands back a client map, not a binary; the caller streams
  # it and enforces its own limit (see Pleroma.Web.RichMedia.Helpers).
  test "leaves a non-binary streaming body alone" do
    body = %{pid: self(), stream: make_ref()}

    assert {:ok, %Tesla.Env{body: ^body}} =
             get([max_body: 1], %{headers: [], body: body})
  end

  # Rejecting a stream on the header alone would strand the connection lease:
  # the env carrying the pid/stream is the caller's only handle to release it.
  test "does not reject a streaming body on content-length alone" do
    body = %{pid: self(), stream: make_ref()}

    assert {:ok, %Tesla.Env{body: ^body}} =
             get([max_body: 1], %{headers: [{"content-length", "20000000"}], body: body})
  end

  test "ignores content-length on a HEAD response" do
    {c, opts} = client([max_body: 4], %{headers: [{"content-length", "9000000"}], body: ""})

    assert {:ok, %Tesla.Env{status: 200}} = Tesla.head(c, "http://example.com/", opts)
  end

  test "ignores content-length on a bodyless status" do
    client =
      Tesla.client([{MaxBody, nil}], fn env ->
        {:ok, %{env | status: 304, headers: [{"content-length", "9000000"}], body: ""}}
      end)

    assert {:ok, %Tesla.Env{status: 304}} =
             Tesla.get(client, "http://example.com/", opts: [adapter: [max_body: 4]])
  end
end
