# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.ScheduleReachabilityWorkerTest do
  use Pleroma.DataCase, async: true
  use Oban.Testing, repo: Pleroma.Repo

  alias Pleroma.Instances
  alias Pleroma.Workers.Cron.ScheduleReachabilityWorker

  describe "perform/1" do
    test "schedules reachability checks for unreachable servers" do
      # Mark some servers as unreachable
      Instances.set_unreachable("https://example.com")
      Instances.set_unreachable("https://test.com")
      Instances.set_unreachable("https://another.com")

      # Verify they are marked as unreachable
      refute Instances.reachable?("https://example.com")
      refute Instances.reachable?("https://test.com")
      refute Instances.reachable?("https://another.com")

      # Run the worker
      assert :ok = ScheduleReachabilityWorker.perform(%Oban.Job{})

      # Verify ReachabilityWorker jobs were scheduled for each server
      # Note: domains in get_unreachable/0 are without the https:// prefix
      assert_enqueued(
        worker: Pleroma.Workers.ReachabilityWorker,
        args: %{"domain" => "example.com"}
      )

      assert_enqueued(
        worker: Pleroma.Workers.ReachabilityWorker,
        args: %{"domain" => "test.com"}
      )

      assert_enqueued(
        worker: Pleroma.Workers.ReachabilityWorker,
        args: %{"domain" => "another.com"}
      )
    end

    test "handles empty list of unreachable servers" do
      # Ensure no servers are marked as unreachable
      assert [] = Instances.get_unreachable()
      assert :ok = ScheduleReachabilityWorker.perform(%Oban.Job{})
      refute_enqueued(worker: Pleroma.Workers.ReachabilityWorker)
    end
  end
end
