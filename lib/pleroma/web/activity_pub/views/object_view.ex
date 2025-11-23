# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectView do
  use Pleroma.Web, :view
  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils

  def render("object.json", %{object: %Object{} = object}) do
    base = Pleroma.Web.ActivityPub.Utils.make_json_ld_header(object.data)

    additional = Transmogrifier.prepare_object(object.data)
    Map.merge(base, additional)
  end

  def render("object.json", %{object: %Activity{data: %{"type" => activity_type}} = activity})
      when activity_type in ["Create", "Listen"] do
    base = Pleroma.Web.ActivityPub.Utils.make_json_ld_header(activity.data)
    object = Object.normalize(activity, fetch: false)

    additional =
      Transmogrifier.prepare_object(activity.data)
      |> Map.put("object", Transmogrifier.prepare_object(object.data))

    Map.merge(base, additional)
  end

  def render("object.json", %{object: %Activity{} = activity}) do
    base = Pleroma.Web.ActivityPub.Utils.make_json_ld_header(activity.data)
    object_id = object_id_from_activity(activity)

    additional =
      Transmogrifier.prepare_object(activity.data)
      |> Map.put("object", object_id)

    Map.merge(base, additional)
  end

  defp object_id_from_activity(%Activity{object: %Object{data: %{"id" => obj_id}}}), do: obj_id
  defp object_id_from_activity(%Activity{data: %{"object" => ap_object_ref}}), do: Utils.get_ap_id(ap_object_ref)
end
