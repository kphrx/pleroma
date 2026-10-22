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
    Keyword.merge(
      [
        verify: :verify_peer,
        cacertfile: CAStore.file_path(),
        depth: 20,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        partial_chain: &__MODULE__.reject_partial_chain/1
      ],
      overrides
    )
  end

  @doc false
  def reject_partial_chain(_certs), do: :unknown_ca

  @spec put_hackney_ssl_options(keyword()) :: keyword()
  def put_hackney_ssl_options(opts) do
    if opts[:insecure] do
      opts
    else
      Keyword.put(opts, :ssl_options, ssl_options(Keyword.get(opts, :ssl_options, [])))
    end
  end
end
