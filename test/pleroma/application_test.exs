# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ApplicationTest do
  use Pleroma.DataCase

  import ExUnit.CaptureLog

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

  describe "config :pleroma, :logger, :backends: [:console]" do
    setup do
      clear_config([:logger, :backends], [:console])
    end

    test "emits a warning" do
      assert capture_log(fn -> Pleroma.Application.configure_logger() end) =~
        ":console is no longer considered a backend and is enabled by default"
    end
  end
end
