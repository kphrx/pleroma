# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.UserSocketTest do
  use Pleroma.Web.ChannelCase
  alias Pleroma.Web.UserSocket

  import Pleroma.Factory

  test "it connects with a valid token" do
    user = insert(:user)
    token = Phoenix.Token.sign(Pleroma.Web.Endpoint, "user socket", user.id)

    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.user_name == user.nickname
  end

  # A crash here would put the secret key base into the error log.
  test "it rejects tokens that are not strings" do
    for token <- [["x"], 123, %{"a" => "b"}] do
      assert :error = connect(UserSocket, %{"token" => token})
    end
  end
end
