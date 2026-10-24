# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.AdapterHelper.TeslaAdapterTest do
  use ExUnit.Case, async: false

  alias Pleroma.HTTP.AdapterHelper
  alias Pleroma.HTTP.TLS

  setup do
    adapter = Application.get_env(:tesla, :adapter)
    on_exit(fn -> Application.put_env(:tesla, :adapter, adapter) end)
  end

  test "adds the TLS options to Hackney" do
    Application.put_env(:tesla, :adapter, Tesla.Adapter.Hackney)

    assert {Tesla.Adapter.Hackney, opts} = AdapterHelper.tesla_adapter()
    assert opts[:ssl_options] == TLS.ssl_options()
    assert opts[:proxy_ssl_options] == TLS.ssl_options()
  end

  test "turns on certificate checks for Gun" do
    Application.put_env(:tesla, :adapter, Tesla.Adapter.Gun)

    assert AdapterHelper.tesla_adapter() == {Tesla.Adapter.Gun, certificates_verification: true}
  end

  test "keeps other adapters" do
    Application.put_env(:tesla, :adapter, {Tesla.Adapter.Finch, name: MyFinch})

    assert AdapterHelper.tesla_adapter() == {Tesla.Adapter.Finch, name: MyFinch}
  end
end
