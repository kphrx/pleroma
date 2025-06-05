# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.InstancesTest do
  alias Pleroma.Instances

  use Pleroma.DataCase

  describe "reachable?/1" do
    test "returns `true` for host / url with unknown reachability status" do
      assert Instances.reachable?("unknown.site")
      assert Instances.reachable?("http://unknown.site")
    end
  end

  describe "filter_reachable/1" do
    setup do
      unreachable_host = "consistently-unreachable.name"
      reachable_host = "http://domain.com/path"

      Instances.set_unreachable(unreachable_host)

      result = Instances.filter_reachable([unreachable_host, reachable_host, nil])
      %{result: result, reachable_host: reachable_host, unreachable_host: unreachable_host}
    end

    test "returns a list of only reachable elements",
         %{result: result, reachable_host: reachable_host} do
      assert is_list(result)
      assert [reachable_host] == result
    end

    test "returns an empty list when provided no data" do
      assert [] == Instances.filter_reachable([])
      assert [] == Instances.filter_reachable([nil])
    end
  end

  describe "set_reachable/1" do
    test "sets unreachable url or host reachable" do
      host = "domain.com"
      Instances.set_unreachable(host)
      refute Instances.reachable?(host)

      Instances.set_reachable(host)
      assert Instances.reachable?(host)
    end

    test "keeps reachable url or host reachable" do
      url = "https://site.name?q="
      assert Instances.reachable?(url)

      Instances.set_reachable(url)
      assert Instances.reachable?(url)
    end

    test "returns error status on non-binary input" do
      assert {:error, _} = Instances.set_reachable(nil)
      assert {:error, _} = Instances.set_reachable(1)
    end
  end

  # Note: implementation-specific (e.g. Instance) details of set_unreachable/1
  # should be tested in implementation-specific tests
  describe "set_unreachable/1" do
    test "returns error status on non-binary input" do
      assert {:error, _} = Instances.set_unreachable(nil)
      assert {:error, _} = Instances.set_unreachable(1)
    end
  end
end
