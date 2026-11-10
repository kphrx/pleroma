# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RichMedia.Parsers.OEmbed do
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
         {:ok, %{"html" => html} = data} <- Jason.decode(json) do
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
