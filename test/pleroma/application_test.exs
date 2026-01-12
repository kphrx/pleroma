# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ApplicationTest do
  use Pleroma.DataCase

  import ExUnit.CaptureLog

  # clear_config/2 can only manipulate env under :pleroma.
  describe "config :logger, backends: []" do
    setup do
      Application.put_env(:logger, :backends, [:console, {ExSyslogger, :ex_syslogger}])

      on_exit(fn ->
        Application.delete_env(:logger, :backends) end)
    end

    test "warns on deprecated syntax" do
      assert capture_log(fn -> Pleroma.Application.configure_logger() end) =~
        "'config :logger, backends: [...]' is deprecated syntax due to changes in Elixir. Use 'config :pleroma, :logger, backends: [...]' instead."
    end
  end

  describe "config :pleroma, :logger, backends: [{:ex_syslogger, :ex_syslogger}]" do
    setup do
      clear_config([:logger, :backends], [{:ex_syslogger, :ex_syslogger}])
    end

    test "is handled" do
      log = capture_log(fn -> Pleroma.Application.configure_logger() end)

      assert log =~ "Configuration {:ex_syslogger, :ex_syslogger} is incorrect. Use {ExSyslogger, :ex_syslogger} instead!"
      assert log =~ "Successfully added logger backend: {ExSyslogger, :ex_syslogger}"
    end
  end
end
