# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.TLSTest do
  use ExUnit.Case, async: true

  alias Pleroma.HTTP.TLS

  describe "ssl_options/1" do
    test "verifies peers against the CAStore bundle" do
      opts = TLS.ssl_options()

      assert opts[:verify] == :verify_peer
      assert opts[:cacertfile] == CAStore.file_path()
      assert [match_fun: match_fun] = opts[:customize_hostname_check]
      assert is_function(match_fun, 2)
    end

    test "does not accept certificates from the peer chain as trust anchors" do
      partial_chain = TLS.ssl_options()[:partial_chain]

      assert partial_chain.([:certificate]) == :unknown_ca
    end

    test "keeps the CA bundle when other options are given" do
      opts = TLS.ssl_options(versions: [:"tlsv1.2"])

      assert opts[:versions] == [:"tlsv1.2"]
      assert opts[:cacertfile] == CAStore.file_path()
      assert opts[:verify] == :verify_peer
    end
  end

  describe "put_hackney_ssl_options/1" do
    test "adds the TLS options" do
      opts = TLS.put_hackney_ssl_options(pool: :media)

      assert opts[:pool] == :media
      assert opts[:ssl_options] == TLS.ssl_options()
    end

    test "merges given ssl_options into the TLS options" do
      opts = TLS.put_hackney_ssl_options(ssl_options: [versions: [:"tlsv1.2"]])

      assert opts[:ssl_options] == TLS.ssl_options(versions: [:"tlsv1.2"])
    end

    test "leaves insecure requests alone" do
      assert TLS.put_hackney_ssl_options(insecure: true) == [insecure: true]
    end
  end
end
