# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RichMedia.Parsers.OEmbed do
  # YouTube often serves server IPs a captcha redirect or a page without
  # metadata, while its oEmbed endpoint keeps working. Ask it directly.
  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be)
  @youtube_endpoint "https://www.youtube.com/oembed"

  @doc """
  Fetches oEmbed data straight from the provider endpoint for known hosts
  (YouTube), without loading the page first.
  """
  @spec direct_lookup(String.t()) :: {:ok, map()} | :error
  def direct_lookup(url) do
    with %URI{host: host} when is_binary(host) <- URI.parse(url),
         true <- String.downcase(host) in @youtube_hosts do
      get_oembed_data(@youtube_endpoint <> "?" <> URI.encode_query(url: url, format: "json"))
    else
      _ -> :error
    end
  end

  def parse(html, _data) do
    with elements = [_ | _] <- get_discovery_data(html),
         oembed_url when is_binary(oembed_url) <- get_oembed_url(elements),
         :ok <- Pleroma.Web.RichMedia.Helpers.validate_page_url(oembed_url),
         {:ok, oembed_data} <- get_oembed_data(oembed_url) do
      oembed_data
    else
      _e -> %{}
    end
  end

  defp get_discovery_data(html) do
    html |> Floki.find("link[type='application/json+oembed']")
  end

  defp get_oembed_url([{"link", attributes, _children} | _]) do
    Enum.find_value(attributes, fn {k, v} -> if k == "href", do: v end)
  end

  defp get_oembed_data(url) do
    with {:ok, json} <- Pleroma.Web.RichMedia.Helpers.rich_media_get(url, accept: :json),
         {:ok, %{"html" => html} = data} when is_binary(html) <- Jason.decode(json) do
      {:ok,
       data
       |> Map.put("html", Pleroma.HTML.filter_tags(html))
       |> put_image()}
    else
      _ -> :error
    end
  end

  defp put_image(%{"thumbnail_url" => url} = data) when is_binary(url),
    do: Map.put_new(data, "image", url)

  defp put_image(data), do: data
end
