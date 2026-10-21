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

  describe "options/2" do
    setup do: clear_config([:http, :adapter], a: 1, b: 2)

    test "uses redirect-safe defaults", %{uri: uri} do
      opts = Hackney.options([], uri)

      assert opts[:follow_redirect] == false
      assert opts[:force_redirect] == false
      assert opts[:with_body] == true
    end

    test "add proxy and opts from config", %{uri: uri} do
      opts = Hackney.options([proxy: "localhost:8123"], uri)

      assert opts[:a] == 1
      assert opts[:b] == 2
      assert opts[:proxy] == "localhost:8123"
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
