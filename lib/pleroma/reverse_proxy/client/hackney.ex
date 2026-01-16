# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxy.Client.Hackney do
  @behaviour Pleroma.ReverseProxy.Client

  # In-app redirect handler to avoid Hackney redirect bugs:
  # - https://github.com/benoitc/hackney/issues/527 (relative/protocol-less redirects can crash Hackney)
  # - https://github.com/benoitc/hackney/issues/273 (redirects not followed when using HTTP proxy)
  #
  # Based on a redirect handler from Pleb, slightly modified to work with Hackney:
  # https://declin.eu/objects/d4f38e62-5429-4614-86d1-e8fc16e6bf33
  @redirect_statuses [301, 302, 303, 307, 308]
  defp absolute_redirect_url(original_url, resp_headers) do
    location =
      Enum.find(resp_headers, fn {header, _location} ->
        String.downcase(header) == "location"
      end)

    URI.merge(original_url, elem(location, 1))
    |> URI.to_string()
  end

  @impl true
  def request(method, url, headers, body, opts \\ []) do
    opts =
      Keyword.put_new(opts, :path_encode_fun, fn path ->
        path
      end)

    if opts[:follow_redirect] != false do
      {_state, req_opts} = Access.get_and_update(opts, :follow_redirect, fn a -> {a, false} end)
      res = :hackney.request(method, url, headers, body, req_opts)

      case res do
        {:ok, code, resp_headers, _client} when code in @redirect_statuses ->
          :hackney.request(
            method,
            absolute_redirect_url(url, resp_headers),
            headers,
            body,
            req_opts
          )

        {:ok, code, resp_headers} when code in @redirect_statuses ->
          :hackney.request(
            method,
            absolute_redirect_url(url, resp_headers),
            headers,
            body,
            req_opts
          )

        _ ->
          res
      end
    else
      :hackney.request(method, url, headers, body, opts)
    end
  end

  @impl true
  def stream_body(ref) do
    case :hackney.stream_body(ref) do
      :done -> :done
      {:ok, data} -> {:ok, data, ref}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def close(ref), do: :hackney.close(ref)
end
