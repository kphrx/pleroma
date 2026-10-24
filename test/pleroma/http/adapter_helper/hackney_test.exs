# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.AdapterHelper.HackneyTest do
  use ExUnit.Case
  use Pleroma.Tests.Helpers

  alias Pleroma.HTTP.AdapterHelper.Hackney

  setup_all do
    uri = URI.parse("http://domain.com")
    {:ok, uri: uri}
  end

  # Hackney 4 shares one HTTP/2 connection per host, and closing a response
  # stops that connection for every stream on it.
  test "Hackney only speaks HTTP/1.1" do
    assert :hackney_util.default_protocols() == [:http1]
  end

  describe "options/2" do
    setup do: clear_config([:http, :adapter], a: 1, b: 2)

    test "uses redirect-safe defaults", %{uri: uri} do
      opts = Hackney.options([], uri)

      assert opts[:follow_redirect] == false
      assert opts[:force_redirect] == false
      assert opts[:with_body] == true
    end

    test "does not allow connection options to enable Hackney redirects", %{uri: uri} do
      opts = Hackney.options([follow_redirect: true, force_redirect: true], uri)

      assert opts[:follow_redirect] == false
      assert opts[:force_redirect] == false
    end

    test "add proxy and opts from config", %{uri: uri} do
      opts = Hackney.options([proxy: "localhost:8123"], uri)

      assert opts[:a] == 1
      assert opts[:b] == 2
      assert opts[:proxy] == "localhost:8123"
    end

    test "gives Hackney a string host for a proxy with an IP address", %{uri: uri} do
      clear_config([:http, :proxy_url], {:socks5, {127, 0, 0, 1}, 9050})
      assert Hackney.options([], uri)[:proxy] == {:socks5, ~c"127.0.0.1", 9050}

      clear_config([:http, :proxy_url], {{10, 0, 0, 1}, 8123})
      assert Hackney.options([], uri)[:proxy] == {~c"10.0.0.1", 8123}

      clear_config([:http, :proxy_url], nil)

      assert Hackney.options([proxy: {:socks5, {0, 0, 0, 0, 0, 0, 0, 1}, 9050}], uri)[:proxy] ==
               {:socks5, ~c"::1", 9050}
    end

    test "respect connection opts and no proxy", %{uri: uri} do
      opts = Hackney.options([a: 2, b: 1], uri)

      assert opts[:a] == 2
      assert opts[:b] == 1
      refute Keyword.has_key?(opts, :proxy)
    end

    test "trusts the CAStore bundle", %{uri: uri} do
      opts = Hackney.options([], uri)

      assert opts[:ssl_options] == Pleroma.HTTP.TLS.ssl_options()
    end

    test "keeps the CAStore bundle with configured ssl_options", %{uri: uri} do
      clear_config([:http, :adapter], ssl_options: [versions: [:"tlsv1.2"]])

      opts = Hackney.options([], uri)

      assert opts[:ssl_options][:versions] == [:"tlsv1.2"]
      assert opts[:ssl_options][:cacertfile] == CAStore.file_path()
    end
  end
end
