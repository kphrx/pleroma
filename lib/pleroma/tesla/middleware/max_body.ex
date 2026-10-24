# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Tesla.Middleware.MaxBody do
  @moduledoc """
  Enforces the `:max_body` adapter option for every adapter.

  `Pleroma.HTTP.Adapter.Gun` applies the limit as it accumulates a `:plain`
  body, so an oversized response is abandoned mid-transfer. Hackney cannot:
  since 4.0 it ignores `with_body` and always hands back a fully read binary
  (`hackney:request/5`), so `Tesla.Adapter.Hackney` never takes the branch that
  would honour `:max_body`. Without this middleware the option is silently
  unenforced there.

  The check therefore bounds what callers are handed, and refuses up front when
  `content-length` already announces too much. It cannot bound peak memory on
  the hackney path, because the adapter has read the body before any middleware
  runs.

  Streaming bodies are left alone: neither adapter limits those, and the caller
  that owns the stream is the one that has to drain and release it.
  """

  @behaviour Tesla.Middleware

  @impl Tesla.Middleware
  def call(%Tesla.Env{opts: opts} = env, next, _opts) do
    case opts[:adapter][:max_body] do
      limit when is_integer(limit) and limit >= 0 -> run(env, next, limit)
      _ -> Tesla.run(env, next)
    end
  end

  defp run(env, next, limit) do
    with {:ok, env} <- Tesla.run(env, next),
         :ok <- check(env, limit) do
      {:ok, env}
    end
  end

  defp check(%Tesla.Env{body: body} = env, limit) when is_binary(body) do
    with :ok <- check_content_length(env, limit) do
      check_body(body, limit)
    end
  end

  # body_as: :chunks and response: :stream hand back a client the caller drains
  # itself, applying its own limit (Pleroma.Web.RichMedia.Helpers). There is
  # nothing to measure, and failing on the header alone would strand the pool
  # lease that only the caller holds a handle to.
  defp check(_env, _limit), do: :ok

  # A bodyless response may still announce the entity's size.
  defp check_content_length(%Tesla.Env{method: :head}, _limit), do: :ok

  defp check_content_length(%Tesla.Env{status: status}, _limit) when status in [204, 304],
    do: :ok

  defp check_content_length(env, limit) do
    with value when is_binary(value) <- Tesla.get_header(env, "content-length"),
         {length, ""} <- Integer.parse(value) do
      if length > limit, do: {:error, :body_too_large}, else: :ok
    else
      _ -> :ok
    end
  end

  defp check_body(body, limit) do
    if byte_size(body) > limit, do: {:error, :body_too_large}, else: :ok
  end
end
