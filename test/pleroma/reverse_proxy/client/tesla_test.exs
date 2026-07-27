# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxy.Client.TeslaTest do
  use ExUnit.Case

  import Mox

  alias Pleroma.ReverseProxy.Client.Tesla

  setup :verify_on_exit!

  test "cancels an unfinished stream before releasing its connection" do
    conn = self()
    stream = [make_ref(), make_ref()]

    expect(Pleroma.GunMock, :cancel, fn ^conn, ^stream -> :ok end)

    assert :ok = Tesla.close(%{pid: conn, stream: stream})
  end
end
