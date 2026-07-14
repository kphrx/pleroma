# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AttachmentTypeSniffer do
  @moduledoc """
  Best-effort MIME sniffing for remote attachments whose declared type is
  unusable (missing or `application/octet-stream`).

  Fetches the first chunk of the URL and runs it through libmagic. Only
  `image/*` results are returned; anything else, or any failure, yields `nil` —
  so this never reclassifies non-image media and never blocks ingestion. This
  exists because some remotes (e.g. extensionless Cloudflare Images URLs) ship
  attachments with no usable `mediaType`, which would otherwise render in the
  timeline as a clickable link instead of an inline image.
  """

  alias Pleroma.HTTP

  require Logger

  # libmagic only needs the file header; a few KB is plenty and keeps the
  # request cheap even when the origin ignores Range.
  @sniff_bytes 8 * 1024
  @timeout 5_000

  @spec sniff_image_type(binary() | nil) :: {:ok, binary() | nil}
  def sniff_image_type(url) when is_binary(url) and url != "" do
    do_sniff(url)
  rescue
    e ->
      Logger.debug(
        "Attachment type sniff failed for #{url}: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:ok, nil}
  end

  def sniff_image_type(_), do: {:ok, nil}

  defp do_sniff(url) do
    headers = [{"range", "bytes=0-#{@sniff_bytes - 1}"}]
    opts = [pool: :media, timeout: @timeout, recv_timeout: @timeout]

    with {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 <-
           HTTP.get(url, headers, opts),
         false <- blank?(body),
         {:ok, %{mime_type: mime}} <- Majic.perform({:bytes, body}, pool: Pleroma.MajicPool),
         true <- String.starts_with?(mime, "image/") do
      {:ok, mime}
    else
      _ -> {:ok, nil}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
