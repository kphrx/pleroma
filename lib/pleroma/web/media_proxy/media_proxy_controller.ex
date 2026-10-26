# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MediaProxy.MediaProxyController do
  use Pleroma.Web, :controller

  alias Pleroma.Config
  alias Pleroma.Helpers.MediaHelper
  alias Pleroma.Helpers.UriHelper
  alias Pleroma.ReverseProxy
  alias Pleroma.Web.MediaProxy
  alias Plug.Conn

  plug(:sandbox)

  def remote(conn, %{"sig" => sig64, "url" => url64}) do
    with {_, true} <- {:enabled, MediaProxy.enabled?()},
         {:ok, url} <- MediaProxy.decode_url(sig64, url64),
         {_, false} <- {:in_banned_urls, MediaProxy.in_banned_urls(url)},
         :ok <- MediaProxy.verify_request_path_and_url(conn, url) do
      ReverseProxy.call(conn, url, media_proxy_opts())
    else
      {:enabled, false} ->
        send_resp(conn, 404, Conn.Status.reason_phrase(404))

      {:in_banned_urls, true} ->
        send_resp(conn, 404, Conn.Status.reason_phrase(404))

      {:error, :invalid_signature} ->
        send_resp(conn, 403, Conn.Status.reason_phrase(403))

      {:wrong_filename, filename} ->
        redirect(conn, external: MediaProxy.build_url(sig64, url64, filename))
    end
  end

  def preview(%Conn{} = conn, %{"sig" => sig64, "url" => url64}) do
    with {_, true} <- {:enabled, MediaProxy.preview_enabled?()},
         {:ok, url} <- MediaProxy.decode_url(sig64, url64),
         :ok <- MediaProxy.verify_request_path_and_url(conn, url),
         {:ok, dimensions} <- preview_dimensions(conn.params["size"]) do
      conn
      |> choose_avif(conn.params["size"])
      |> handle_preview(url, dimensions)
    else
      {:enabled, false} ->
        send_resp(conn, 404, Conn.Status.reason_phrase(404))

      {:error, :invalid_signature} ->
        send_resp(conn, 403, Conn.Status.reason_phrase(403))

      {:wrong_filename, filename} ->
        redirect(conn, external: MediaProxy.build_preview_url(sig64, url64, filename))

      # only the configured sizes: any other value would be one more resize
      # and one more cache entry
      :unknown_size ->
        drop_param_and_redirect(conn, "size")
    end
  end

  # the box an image preview fits in: the thumbnail's, or a configured size
  # (the long side)
  defp preview_dimensions(nil), do: {:ok, thumbnail_max_dimensions()}

  # exactly as configured: "+960" or "0960" would be the same size under
  # another cache key
  defp preview_dimensions(size) when is_binary(size) do
    case Enum.find(MediaProxy.image_sizes(), &(to_string(&1) == size)) do
      nil -> :unknown_size
      size -> {:ok, {size, size}}
    end
  end

  defp preview_dimensions(_size), do: :unknown_size

  # A size (not the thumbnail) as AVIF, when it is on, this libvips can
  # encode it and the client takes it. The answer then depends on Accept:
  # caches must keep the formats apart.
  defp choose_avif(conn, nil), do: conn

  defp choose_avif(conn, _size) do
    if Keyword.get(media_preview_proxy_config(), :avif, false) and
         MediaHelper.avif_supported?() do
      accepts_avif? =
        conn
        |> get_req_header("accept")
        |> Enum.any?(&String.contains?(&1, "image/avif"))

      conn
      |> put_resp_header("vary", "accept")
      |> assign(:preview_avif, accepts_avif?)
    else
      conn
    end
  end

  defp handle_preview(conn, url, dimensions) do
    media_proxy_url = MediaProxy.url(url)
    http_client_opts = Pleroma.Config.get([:media_proxy, :proxy_opts, :http], pool: :media)

    with {:ok, %{status: status} = head_response} when status in 200..299 <-
           Pleroma.HTTP.request(:head, media_proxy_url, "", [], http_client_opts) do
      content_type = Tesla.get_header(head_response, "content-type")
      content_length = Tesla.get_header(head_response, "content-length")
      content_length = content_length && String.to_integer(content_length)
      static = conn.params["static"] in ["true", true]

      cond do
        # an animated WebP only shows after the download: a still WebP
        # gets the same still preview
        static and content_type in ["image/gif", "image/webp"] ->
          handle_jpeg_preview(conn, media_proxy_url, dimensions, still: true)

        static ->
          drop_param_and_redirect(conn, "static")

        content_type == "image/gif" ->
          redirect_to_original(conn, media_proxy_url)

        min_content_length_for_preview() > 0 and content_length > 0 and
            content_length < min_content_length_for_preview() ->
          redirect_to_original(conn, media_proxy_url)

        true ->
          handle_preview(content_type, conn, media_proxy_url, dimensions)
      end
    else
      # If HEAD failed, redirecting to media proxy URI doesn't make much sense; returning an error
      {_, %{status: status}} ->
        send_resp(conn, :failed_dependency, "Can't fetch HTTP headers (HTTP #{status}).")

      {:error, :recv_response_timeout} ->
        send_resp(conn, :failed_dependency, "HEAD request timeout.")

      _ ->
        send_resp(conn, :failed_dependency, "Can't fetch HTTP headers.")
    end
  end

  defp handle_preview(
         "image/" <> _ = content_type,
         %{assigns: %{preview_avif: true}} = conn,
         media_proxy_url,
         dimensions
       ) do
    case avif_preview(media_proxy_url, dimensions) do
      {:ok, binary} ->
        conn
        |> put_preview_response_headers(["image/avif", "preview.avif"])
        |> send_resp(200, binary)

      {:error, :animated} ->
        redirect_to_original(conn, media_proxy_url)

      # an encoder that fails (a libheif without AV1): JPEG/PNG, not the
      # original
      _ ->
        handle_preview(
          content_type,
          assign(conn, :preview_avif, false),
          media_proxy_url,
          dimensions
        )
    end
  end

  defp handle_preview("image/png" <> _ = _content_type, conn, media_proxy_url, dimensions) do
    handle_png_preview(conn, media_proxy_url, dimensions)
  end

  defp handle_preview("image/" <> _ = _content_type, conn, media_proxy_url, dimensions) do
    handle_jpeg_preview(conn, media_proxy_url, dimensions)
  end

  defp handle_preview("video/" <> _ = _content_type, conn, media_proxy_url, _dimensions) do
    handle_video_preview(conn, media_proxy_url)
  end

  defp handle_preview(_unsupported_content_type, conn, media_proxy_url, _dimensions) do
    fallback_on_preview_error(conn, media_proxy_url)
  end

  defp handle_png_preview(conn, media_proxy_url, {thumbnail_max_width, thumbnail_max_height}) do
    quality = Config.get!([:media_preview_proxy, :image_quality])

    with {:ok, thumbnail_binary} <-
           MediaHelper.image_resize(
             media_proxy_url,
             %{
               max_width: thumbnail_max_width,
               max_height: thumbnail_max_height,
               quality: quality,
               format: "png"
             }
           ) do
      conn
      |> put_preview_response_headers(["image/png", "preview.png"])
      |> send_resp(200, thumbnail_binary)
    else
      {:error, :animated} ->
        redirect_to_original(conn, media_proxy_url)

      _ ->
        fallback_on_preview_error(conn, media_proxy_url)
    end
  end

  defp avif_preview(media_proxy_url, {max_width, max_height}) do
    config = media_preview_proxy_config()

    MediaHelper.image_resize(media_proxy_url, %{
      max_width: max_width,
      max_height: max_height,
      quality: Keyword.get(config, :avif_quality, 55),
      effort: Keyword.get(config, :avif_effort, 3),
      format: "avif"
    })
  end

  defp handle_jpeg_preview(
         conn,
         media_proxy_url,
         {thumbnail_max_width, thumbnail_max_height},
         opts \\ []
       ) do
    quality = Config.get!([:media_preview_proxy, :image_quality])

    with {:ok, thumbnail_binary} <-
           MediaHelper.image_resize(
             media_proxy_url,
             %{
               max_width: thumbnail_max_width,
               max_height: thumbnail_max_height,
               quality: quality,
               still: Keyword.get(opts, :still, false)
             }
           ) do
      conn
      |> put_preview_response_headers()
      |> send_resp(200, thumbnail_binary)
    else
      {:error, :animated} ->
        redirect_to_original(conn, media_proxy_url)

      _ ->
        fallback_on_preview_error(conn, media_proxy_url)
    end
  end

  defp handle_video_preview(conn, media_proxy_url) do
    with {:ok, thumbnail_binary} <-
           MediaHelper.video_framegrab(media_proxy_url) do
      conn
      |> put_preview_response_headers()
      |> send_resp(200, thumbnail_binary)
    else
      _ ->
        fallback_on_preview_error(conn, media_proxy_url)
    end
  end

  defp drop_param_and_redirect(conn, param) do
    uri_without_param =
      conn
      |> current_url()
      |> UriHelper.modify_uri_params(%{}, [param])

    redirect(conn, external: uri_without_param)
  end

  defp fallback_on_preview_error(conn, media_proxy_url) do
    redirect(conn, external: media_proxy_url)
  end

  # animated (GIF, animated WebP) or too small for a preview
  defp redirect_to_original(conn, media_proxy_url) do
    conn
    |> put_status(301)
    |> redirect(external: media_proxy_url)
  end

  defp put_preview_response_headers(
         conn,
         [content_type, filename] = _content_info \\ ["image/jpeg", "preview.jpg"]
       ) do
    conn
    |> put_resp_header("content-type", content_type)
    |> put_resp_header("content-disposition", "inline; filename=\"#{filename}\"")
    |> put_resp_header("cache-control", ReverseProxy.default_cache_control_header())
  end

  defp thumbnail_max_dimensions do
    config = media_preview_proxy_config()

    thumbnail_max_width = Keyword.fetch!(config, :thumbnail_max_width)
    thumbnail_max_height = Keyword.fetch!(config, :thumbnail_max_height)

    {thumbnail_max_width, thumbnail_max_height}
  end

  defp min_content_length_for_preview do
    Keyword.get(media_preview_proxy_config(), :min_content_length, 0)
  end

  defp media_preview_proxy_config do
    Config.get!([:media_preview_proxy])
  end

  defp media_proxy_opts do
    Config.get([:media_proxy, :proxy_opts], [])
  end

  defp sandbox(conn, _params) do
    conn
    |> merge_resp_headers([{"content-security-policy", "sandbox;"}])
  end
end
