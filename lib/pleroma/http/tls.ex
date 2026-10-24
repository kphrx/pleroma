# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.TLS do
  @moduledoc """
  TLS client options that trust the CAStore bundle.

  Hackney otherwise trusts its own certifi bundle. Hackney 1 drops all of its
  default TLS options, including certificate checks, as soon as any
  `ssl_options` are given. Hackney 4 merges them, so `partial_chain` must be
  set too: Hackney's own one trusts any certificate in the peer chain that is
  in certifi.
  """

  @spec ssl_options(keyword()) :: keyword()
  def ssl_options(overrides \\ []) do
    defaults = [
      verify: :verify_peer,
      cacertfile: CAStore.file_path(),
      depth: 20,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      partial_chain: &__MODULE__.reject_partial_chain/1
    ]

    # Hackney drops cacerts when cacertfile is set too.
    defaults =
      if Keyword.has_key?(overrides, :cacerts),
        do: Keyword.delete(defaults, :cacertfile),
        else: defaults

    Keyword.merge(defaults, overrides)
  end

  @doc false
  def reject_partial_chain(_certs), do: :unknown_ca

  @spec put_hackney_ssl_options(keyword()) :: keyword()
  def put_hackney_ssl_options(opts) do
    # Hackney 4 ignores the top-level insecure option and falls back to certifi.
    if opts[:insecure] do
      Keyword.put(opts, :ssl_options, verify: :verify_none)
    else
      opts
      |> Keyword.put(:ssl_options, ssl_options(Keyword.get(opts, :ssl_options, [])))
      |> Keyword.put(:proxy_ssl_options, ssl_options(Keyword.get(opts, :proxy_ssl_options, [])))
    end
  end
end
