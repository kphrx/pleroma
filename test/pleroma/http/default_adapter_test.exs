# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.DefaultAdapterTest do
  use ExUnit.Case, async: true

  # The test environment uses Tesla.Mock, and config.exs imports the config
  # of the current Mix env, so check the shipped default in the file itself.
  test "Gun is the default HTTP client" do
    assert File.read!("config/config.exs") =~ ~r/^config :tesla, adapter: Tesla.Adapter.Gun$/m
  end
end
