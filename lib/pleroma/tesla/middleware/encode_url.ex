# Pleroma: A lightweight social networking server
# Copyright © 2017-2025 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Tesla.Middleware.EncodeUrl do
  @moduledoc """
  Middleware to encode URLs properly

  We must decode and then re-encode to ensure correct encoding.
  If we only encode it will re-encode each % as %25 causing a space
  already encoded as %20 to be %2520.

  Similar problem for query parameters which need spaces to be the + character
  """

  @behaviour Tesla.Middleware

  @impl Tesla.Middleware
  def call(%Tesla.Env{url: url} = env, next, _) do
    url =
      URI.parse(url)
      |> then(fn parsed ->
        path = encode_path(parsed.path)
        query = encode_query(parsed.query)

        %{parsed | path: path, query: query}
      end)
      |> URI.to_string()

    env = %{env | url: url}

    case Tesla.run(env, next) do
      {:ok, env} -> {:ok, env}
      err -> err
    end
  end

  defp encode_path(nil), do: nil

  defp encode_path(path) when is_binary(path) do
    path
    |> URI.decode()
    |> URI.encode()
  end

  defp encode_query(nil), do: nil

  defp encode_query(query) when is_binary(query) do
    query
    |> URI.decode_query()
    |> URI.encode_query()
  end
end
