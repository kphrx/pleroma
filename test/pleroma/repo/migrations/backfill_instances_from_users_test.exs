# Pleroma: A lightweight social networking server
# Copyright © 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.BackfillInstancesFromUsersTest do
  use Pleroma.DataCase
  import Pleroma.Factory
  import Pleroma.Tests.Helpers

  alias Pleroma.Instances.Instance

  setup_all do: require_migration("20261028000000_backfill_instances_from_users")

  test "up/0 adds the hosts of remote users and keeps existing records", %{migration: migration} do
    unreachable_since = ~N[2020-01-01 00:00:00.000000]
    insert(:instance, host: "known.example", unreachable_since: unreachable_since)

    insert(:user, local: false, ap_id: "https://known.example/users/a")
    insert(:user, local: false, ap_id: "https://new.example/users/a")
    insert(:user, local: false, ap_id: "https://new.example/users/b")
    insert(:user, local: false, ap_id: "https://ported.example:8443/users/c")
    insert(:user, local: false, ap_id: "https://user@userinfo.example/users/d")
    insert(:user, local: false, ap_id: "https://[2001:db8::1]/users/e")
    insert(:user, local: true)

    migration.up()

    hosts = Instance |> Repo.all() |> Enum.map(& &1.host) |> Enum.sort()
    assert hosts == ["known.example", "new.example", "ported.example", "userinfo.example"]

    assert %{unreachable_since: ^unreachable_since} = Repo.get_by(Instance, host: "known.example")
  end
end
