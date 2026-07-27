# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Federator.Publishing do
  @callback perform(atom(), any()) :: :ok | {:ok, any()} | {:error, any()}
  @callback publish(map()) :: any()
end
