# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.HTTPSignaturePlugMRFTest do
  # Not async: the MRF settings are global config.
  use Pleroma.Web.ConnCase

  alias Pleroma.StaticStubbedConfigMock, as: ConfigMock
  alias Pleroma.StubbedHTTPSignaturesMock, as: HTTPSignaturesMock
  alias Pleroma.Web.Plugs.HTTPSignaturePlug

  import Mox
  import Phoenix.Controller, only: [put_format: 2]
  import Plug.Conn

  setup do: clear_config([:mrf, :policies], [Pleroma.Web.ActivityPub.MRF.SimplePolicy])
  setup do: clear_config([:mrf_simple, :reject], [{"mastodon.example.org", "no reason"}])

  defp signed_get(actor) do
    ConfigMock
    |> expect(:get, fn [:activitypub, :authorized_fetch_mode], false -> true end)
    |> expect(:get, fn [:instance, :rejected_instances] -> [] end)

    HTTPSignaturesMock
    |> expect(:validate_conn, fn _ -> true end)

    build_conn(:get, "/doesntmattter", %{"actor" => actor})
    |> put_req_header("date", Pleroma.Signature.signed_date())
    |> put_req_header(
      "signature",
      "keyId=\"#{actor}#main-key\",headers=\"(request-target) host date\",signature=\"fake\""
    )
    |> put_format("activity+json")
    |> HTTPSignaturePlug.call(%{})
  end

  test "rejects signed requests from instances rejected by SimplePolicy" do
    assert signed_get("http://mastodon.example.org/users/admin").halted
    refute signed_get("http://allowed.example.org/users/admin").halted
  end
end
