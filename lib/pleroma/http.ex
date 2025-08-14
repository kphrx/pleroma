# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP do
  @moduledoc """
    Wrapper for `Tesla.request/2`.
  """

  alias Pleroma.HTTP.AdapterHelper
  alias Pleroma.HTTP.Request
  alias Pleroma.HTTP.RequestBuilder, as: Builder
  alias Tesla.Client
  alias Tesla.Env

  require Logger
  require Pleroma.Constants

  @type t :: __MODULE__
  @type method() :: :get | :post | :put | :delete | :head

  @doc """
  Performs GET request.

  See `Pleroma.HTTP.request/5`
  """
  @spec get(Request.url() | nil, Request.headers(), keyword()) ::
          nil | {:ok, Env.t()} | {:error, any()}
  def get(url, headers \\ [], options \\ [])
  def get(nil, _, _), do: nil
  def get(url, headers, options), do: request(:get, url, "", headers, options)

  @spec head(Request.url(), Request.headers(), keyword()) :: {:ok, Env.t()} | {:error, any()}
  def head(url, headers \\ [], options \\ []), do: request(:head, url, "", headers, options)

  @doc """
  Performs POST request.

  See `Pleroma.HTTP.request/5`
  """
  @spec post(Request.url(), Tesla.Env.body(), Request.headers(), keyword()) ::
          {:ok, Env.t()} | {:error, any()}
  def post(url, body, headers \\ [], options \\ []),
    do: request(:post, url, body, headers, options)

  @doc """
  Builds and performs http request.

  # Arguments:
  `method` - :get, :post, :put, :delete, :head
  `url` - full url
  `body` - request body
  `headers` - a keyworld list of headers, e.g. `[{"content-type", "text/plain"}]`
  `options` - custom, per-request middleware or adapter options

  # Returns:
  `{:ok, %Tesla.Env{}}` or `{:error, error}`

  """
  @spec request(method(), Request.url(), Tesla.Env.body(), Request.headers(), keyword()) ::
          {:ok, Env.t()} | {:error, any()}
  def request(method, url, body, headers, options) when is_binary(url) do
    uri = URI.parse(url)
    adapter_opts = AdapterHelper.options(uri, options || [])

    options = put_in(options[:adapter], adapter_opts)
    params = options[:params] || []
    request = build_request(method, headers, options, url, body, params)

    adapter = Application.get_env(:tesla, :adapter)

    extra_middleware = options[:tesla_middleware] || []

    client = Tesla.client(adapter_middlewares(adapter, extra_middleware), adapter)

    maybe_limit(
      fn ->
        request(client, request)
      end,
      adapter,
      adapter_opts
    )
  end

  @spec request(Client.t(), keyword()) :: {:ok, Env.t()} | {:error, any()}
  def request(client, request), do: Tesla.request(client, request)

  defp build_request(method, headers, options, url, body, params) do
    Builder.new()
    |> Builder.method(method)
    |> Builder.headers(headers)
    |> Builder.opts(options)
    |> Builder.url(url)
    |> Builder.add_param(:body, :body, body)
    |> Builder.add_param(:query, :query, params)
    |> Builder.convert_to_keyword()
  end

  @prefix Pleroma.Gun.ConnectionPool
  defp maybe_limit(fun, Tesla.Adapter.Gun, opts) do
    ConcurrentLimiter.limit(:"#{@prefix}.#{opts[:pool] || :default}", fun)
  end

  defp maybe_limit(fun, _, _) do
    fun.()
  end

  defp adapter_middlewares(Tesla.Adapter.Gun, extra_middleware) do
    default_middleware() ++
      [Pleroma.Tesla.Middleware.ConnectionPool] ++
      extra_middleware
  end

  defp adapter_middlewares(_, extra_middleware) do
    # A lot of tests are written expecting unencoded URLs
    # and the burden of fixing that is high. Also it makes
    # them hard to read. Tests will opt-in when we want to validate
    # the encoding is being done correctly.
    cond do
      Pleroma.Config.get(:env) == :test and Pleroma.Config.get(:test_url_encoding) ->
        default_middleware()

      Pleroma.Config.get(:env) == :test ->
        # Emulate redirects in test env, which are handled by adapters in other environments
        [Tesla.Middleware.FollowRedirects]

      # Hackney and Finch
      true ->
        default_middleware() ++ extra_middleware
    end
  end

  defp default_middleware,
    do: [Tesla.Middleware.FollowRedirects, Pleroma.Tesla.Middleware.EncodeUrl]

  def encode_url(url) when is_binary(url) do
    URI.parse(url)
    |> then(fn parsed ->
      path = encode_path(parsed.path)
      query = encode_query(parsed.query)

      %{parsed | path: path, query: query}
    end)
    |> URI.to_string()
  end

  defp encode_path(nil), do: nil

  # URI.encode/2 deliberately does not encode all chars that are forbidden
  # in the path component of a URI. It only encodes chars that are forbidden
  # in the whole URI. A predicate in the 2nd argument is used to fix that here.
  # URI.encode/2 uses the predicate function to determine whether each byte
  # (in an integer representation) should be encoded or not.
  defp encode_path(path) when is_binary(path) do
    path
    |> URI.decode()
    |> URI.encode(fn byte ->
      URI.char_unreserved?(byte) || Enum.any?(
        Pleroma.Constants.uri_path_allowed_reserved_chars, fn char ->
          char == byte end)
    end)
  end

  defp encode_query(nil), do: nil

  defp encode_query(query) when is_binary(query) do
    query
    |> URI.decode_query()
    |> URI.encode_query()
  end
end
