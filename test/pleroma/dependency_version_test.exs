# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.DependencyVersionTest do
  use ExUnit.Case, async: true

  test "uses majic 1.2" do
    majic_version =
      :majic
      |> Application.spec(:vsn)
      |> to_string()

    assert Version.match?(majic_version, "~> 1.2")
  end
end
