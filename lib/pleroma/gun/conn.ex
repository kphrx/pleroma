# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Gun.Conn do
  alias Pleroma.Gun

  require Logger

  def open(%URI{} = uri, opts) do
    pool_opts = Pleroma.Config.get([:connections_pool], [])

    opts =
      opts
      |> Enum.into(%{})
      |> Map.put_new(:connect_timeout, pool_opts[:connect_timeout] || 5_000)
      |> Map.put_new(:supervise, false)
      |> maybe_add_tls_opts(uri)

    do_open(uri, opts)
  end

  defp maybe_add_tls_opts(opts, %URI{scheme: "http"}), do: opts

  defp maybe_add_tls_opts(opts, %URI{scheme: "https"}) do
    tls_opts = [
      verify: :verify_peer,
      cacertfile: CAStore.file_path(),
      depth: 20,
      reuse_sessions: false,
      log_level: :warning,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    tls_opts =
      if Keyword.keyword?(opts[:tls_opts]) do
        Keyword.merge(tls_opts, opts[:tls_opts])
      else
        tls_opts
      end

    Map.put(opts, :tls_opts, tls_opts)
  end

  defp do_open(%URI{scheme: "http"} = uri, %{proxy: {proxy_host, proxy_port}} = opts) do
    with open_opts <- opts |> proxy_open_opts() |> Map.put(:protocols, [:http]),
         {:ok, conn} <- Gun.open(proxy_host, proxy_port, open_opts),
         {:ok, protocol} <- await_up(conn, opts[:connect_timeout]) do
      {:ok, conn, protocol, :forward_proxy}
    else
      error ->
        Logger.warning(
          "Opening forward proxy connection to #{compose_uri_log(uri)} failed with error #{inspect(error)}"
        )

        error
    end
  end

  defp do_open(uri, %{proxy: {proxy_host, proxy_port}} = opts) do
    connect_opts =
      uri
      |> destination_opts()
      |> add_http2_opts(uri.scheme, Map.get(opts, :tls_opts, []))
      |> add_proxy_auth(opts)

    with open_opts <- proxy_open_opts(opts),
         {:ok, conn} <- Gun.open(proxy_host, proxy_port, open_opts),
         {:ok, _proxy_protocol} <- await_up(conn, opts[:connect_timeout]) do
      conn
      |> Gun.connect(connect_opts)
      |> await_proxy_connect(conn, opts[:connect_timeout])
    else
      error ->
        Logger.warning(
          "Opening proxied connection to #{compose_uri_log(uri)} failed with error #{inspect(error)}"
        )

        error
    end
  end

  defp do_open(_uri, %{proxy: {:socks4, _proxy_host, _proxy_port}}) do
    {:error, :socks4_unsupported}
  end

  defp do_open(uri, %{proxy: {proxy_type, proxy_host, proxy_port}} = opts)
       when proxy_type in [:socks, :socks5] do
    socks_opts =
      uri
      |> destination_opts()
      |> add_http2_opts(uri.scheme, Map.get(opts, :tls_opts, []))
      |> Map.put(:version, 5)
      |> add_socks_proxy_auth(opts)

    open_opts =
      opts
      |> proxy_open_opts()
      |> Map.put(:protocols, [:socks])
      |> Map.put(:socks_opts, socks_opts)

    with {:ok, conn} <- Gun.open(proxy_host, proxy_port, open_opts),
         {:ok, :socks} <- await_up(conn, opts[:connect_timeout]),
         {:ok, protocol} <- await_tunnel_up(conn, :undefined, opts[:connect_timeout]) do
      {:ok, conn, protocol, nil}
    else
      error ->
        Logger.warning(
          "Opening socks proxied connection to #{compose_uri_log(uri)} failed with error #{inspect(error)}"
        )

        error
    end
  end

  defp do_open(%URI{host: host, port: port} = uri, opts) do
    host = Pleroma.HTTP.AdapterHelper.parse_host(host)
    opts = Map.put(opts, :transport, transport(uri.scheme))

    with {:ok, conn} <- Gun.open(host, port, opts),
         {:ok, protocol} <- await_up(conn, opts[:connect_timeout]) do
      {:ok, conn, protocol, nil}
    else
      error ->
        Logger.warning(
          "Opening connection to #{compose_uri_log(uri)} failed with error #{inspect(error)}"
        )

        error
    end
  end

  defp destination_opts(%URI{host: host, port: port}) do
    host = Pleroma.HTTP.AdapterHelper.parse_host(host)
    %{host: host, port: port}
  end

  defp add_http2_opts(opts, "https", tls_opts) do
    Map.merge(opts, %{protocols: [:http2, :http], transport: :tls, tls_opts: tls_opts})
  end

  defp add_http2_opts(opts, _, _), do: opts

  defp add_proxy_auth(connect_opts, %{proxy_auth: {username, password}})
       when is_binary(username) and is_binary(password) do
    Map.merge(connect_opts, %{username: username, password: password})
  end

  defp add_proxy_auth(connect_opts, _), do: connect_opts

  defp add_socks_proxy_auth(socks_opts, %{proxy_auth: {username, password}})
       when is_binary(username) and is_binary(password) do
    Map.put(socks_opts, :auth, [{:username_password, username, password}])
  end

  defp add_socks_proxy_auth(socks_opts, _), do: socks_opts

  defp proxy_open_opts(opts) do
    proxy_tls_opts = Map.get(opts, :proxy_tls_opts, [])

    opts =
      opts
      |> Map.drop([:proxy, :proxy_auth, :proxy_tls_opts, :tls_opts])
      |> Map.put_new(:transport, :tcp)

    if opts.transport == :tls do
      Map.put(opts, :tls_opts, proxy_tls_opts)
    else
      opts
    end
  end

  defp await_up(conn, timeout) do
    case Gun.await_up(conn, timeout) do
      {:ok, protocol} ->
        {:ok, protocol}

      error ->
        Gun.close(conn)
        error
    end
  end

  defp await_proxy_connect(stream, conn, timeout) do
    case Gun.await(conn, stream) do
      {:response, :fin, 200, _headers} ->
        case await_tunnel_up(conn, stream, timeout) do
          {:ok, protocol} -> {:ok, conn, protocol, stream}
          error -> error
        end

      {:response, _fin, 407, _headers} ->
        close_with_error(conn, :proxy_auth_failed)

      {:response, _fin, status, _headers} when is_integer(status) ->
        close_with_error(conn, {:proxy_connect_failed, status})

      error ->
        Gun.close(conn)
        error
    end
  end

  defp close_with_error(conn, reason) do
    Gun.close(conn)
    {:error, reason}
  end

  defp transport("https"), do: :tls
  defp transport(_), do: :tcp

  defp await_tunnel_up(conn, stream_ref, timeout) do
    case Gun.await_tunnel_up(conn, stream_ref, timeout) do
      {:ok, protocol} ->
        {:ok, protocol}

      error ->
        Gun.close(conn)
        error
    end
  end

  def compose_uri_log(%URI{scheme: scheme, host: host, path: path}) do
    "#{scheme}://#{host}#{path}"
  end
end
