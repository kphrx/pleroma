# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.EnsureHostMatchesPlug do
  @moduledoc "Ensures Host header matches instance"

  alias Pleroma.Web.Endpoint

  import Plug.Conn

  def init(options), do: options

  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(%Plug.Conn{assigns: %{valid_signature: true}} = conn, _opts) do
    # Host header is scheme-less, URI.parse needs the //
    host_header = get_req_header(conn, "host")
    host_uri = URI.parse("//#{host_header}")
    instance_uri = URI.parse(Endpoint.url())

    case host_header do
      [host] ->
        cond do
          host == "" ->
            resp(conn, 400, "Host header not provided") |> halt()

          true ->
            if host_matches?(host_uri, instance_uri),
              do: assign(conn, :valid_host_header, true),
              else: resp(conn, 400, "Host header does not match this instance") |> halt()
        end

      [_head | _rest] ->
        conn
        |> resp(400, "More than one Host header provided")
        |> halt()

      [] ->
        conn
        |> resp(400, "Host header not provided")
        |> halt()
    end
  end

  # Host header may not be provided, but signature verification failed anyway
  def call(conn, _opts), do: conn

  defp case_insensitive_compare(checked, authority) do
    String.downcase(checked) == String.downcase(authority)
  end

  # Host header did not provide port
  # Host header is scheme-less, URI.parse does not provide default port
  defp host_matches?(%URI{host: req_host, port: nil}, %URI{host: instance_host}),
    do: case_insensitive_compare(req_host, instance_host)

  # Host header provided a port
  # Any port specified in the Endpoint url configuration is valid here
  defp host_matches?(%URI{host: req_host, port: port}, %URI{host: instance_host, port: port}),
    do: case_insensitive_compare(req_host, instance_host)

  defp host_matches?(_, _), do: false
end
