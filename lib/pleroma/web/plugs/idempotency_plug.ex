# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.IdempotencyPlug do
  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias Pleroma.Config

  @behaviour Plug

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)

  # How long a claim placed on a key survives without the owning request
  # completing. Should comfortably exceed the longest expected request; it only
  # bounds how long a key stays blocked when the owner dies before sending a
  # response (in which case no `before_send` callback ever runs).
  @claim_ttl :timer.seconds(60)

  @in_progress :in_progress

  @impl true
  def init(opts), do: opts

  # Sending idempotency keys in `GET` and `DELETE` requests has no effect
  # and should be avoided, as these requests are idempotent by definition.

  @impl true
  def call(%{method: method} = conn, _) when method in ["POST", "PUT", "PATCH"] do
    case get_req_header(conn, "idempotency-key") do
      [key] -> process_request(conn, key)
      _ -> conn
    end
  end

  def call(conn, _), do: conn

  def process_request(conn, key) do
    cache_key = {conn.method, conn.request_path, actor_key(conn), key}

    # Read and claim under the same lock so a retry cannot overwrite a
    # claim or response written after a cache miss.
    case @cachex.get_and_update(:idempotency_cache, cache_key, fn
           nil -> {:commit, @in_progress, ttl: @claim_ttl}
           existing -> {:ignore, existing}
         end) do
      {:commit, @in_progress, _options} ->
        cache_response(conn, key, cache_key)

      {:ignore, @in_progress} ->
        render_in_progress(conn, key)

      {:ignore, record} ->
        send_cached(conn, key, record)

      {:error, message} ->
        render_error(conn, message)
    end
  end

  defp cache_response(conn, key, cache_key) do
    register_before_send(conn, &maybe_cache_response(&1, key, cache_key))
  end

  defp maybe_cache_response(
         %{private: %{skip_idempotency_cache: true}} = conn,
         _key,
         cache_key
       ) do
    # Sensitive responses are not cached; release the claim so that the key
    # is not reported as in progress until the claim expires.
    {:ok, _} = @cachex.del(:idempotency_cache, cache_key)
    conn
  end

  defp maybe_cache_response(conn, key, cache_key) do
    [request_id] = get_resp_header(conn, "x-request-id")
    content_type = get_content_type(conn)

    record = {request_id, content_type, conn.status, conn.resp_body}
    {:ok, _} = @cachex.put(:idempotency_cache, cache_key, record)

    conn
    |> put_resp_header("idempotency-key", key)
    |> put_resp_header("x-original-request-id", request_id)
  end

  defp actor_key(%{assigns: assigns}) do
    {principal_key(assigns), token_key(assigns[:token]), staff_privileges()}
  end

  defp principal_key(%{user: %{id: id} = user}) do
    {:user, id, Map.get(user, :is_admin), Map.get(user, :is_moderator)}
  end

  defp principal_key(%{app: %{id: id}}), do: {:app, id}
  defp principal_key(_assigns), do: nil

  defp token_key(%{id: id} = token), do: {id, token |> Map.get(:scopes, []) |> Enum.sort()}
  defp token_key(_token), do: nil

  defp staff_privileges do
    {
      Config.get([:instance, :admin_privileges], []) |> Enum.sort(),
      Config.get([:instance, :moderator_privileges], []) |> Enum.sort()
    }
  end

  defp send_cached(conn, key, record) do
    {request_id, content_type, status, body} = record

    conn
    |> put_resp_header("idempotency-key", key)
    |> put_resp_header("idempotent-replayed", "true")
    |> put_resp_header("x-original-request-id", request_id)
    |> put_resp_content_type(content_type)
    |> send_resp(status, body)
    |> halt()
  end

  defp render_in_progress(conn, key) do
    conn
    |> put_resp_header("idempotency-key", key)
    |> put_status(:conflict)
    |> json(%{error: "A request with this idempotency key is already in progress"})
    |> halt()
  end

  defp render_error(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
    |> halt()
  end

  defp get_content_type(conn) do
    [content_type] = get_resp_header(conn, "content-type")

    if String.contains?(content_type, ";") do
      content_type
      |> String.split(";")
      |> hd()
    else
      content_type
    end
  end
end
