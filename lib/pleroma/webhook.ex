# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Webhook do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Repo

  @event_types [:"account.created", :"report.created"]

  schema "webhooks" do
    field(:url, ObjectValidators.Uri)
    field(:events, {:array, Ecto.Enum}, values: @event_types, default: [])
    field(:secret, :string, default: "")
    field(:enabled, :boolean, default: true)
    field(:internal, :boolean, default: false)

    timestamps()
  end

  def get(id), do: Repo.get(__MODULE__, id)

  def get_by_type(type) do
    __MODULE__
    |> where([w], ^type in w.events)
    |> where([w], w.enabled == true)
    |> Repo.all()
  end

  def changeset(%__MODULE__{} = webhook, params) do
    webhook
    |> cast(params, [:url, :events, :enabled, :internal])
    |> validate_required([:url, :events])
    |> validate_events_present()
    |> unique_constraint(:url)
    |> put_secret()
  end

  def update_changeset(%__MODULE__{} = webhook, params \\ %{}) do
    webhook
    |> cast(params, [:url, :events, :enabled, :internal])
    |> validate_events_present()
    |> unique_constraint(:url)
  end

  def create(params) do
    %__MODULE__{}
    |> changeset(params)
    |> Repo.insert()
  end

  def update(%__MODULE__{} = webhook, params) do
    webhook
    |> update_changeset(params)
    |> Repo.update()
  end

  def delete(webhook), do: webhook |> Repo.delete()

  def rotate_secret(%__MODULE__{} = webhook) do
    webhook
    |> cast(%{}, [])
    |> put_secret()
    |> Repo.update()
  end

  def set_enabled(%__MODULE__{} = webhook, enabled) do
    webhook
    |> cast(%{enabled: enabled}, [:enabled])
    |> Repo.update()
  end

  defp validate_events_present(changeset) do
    cond do
      Keyword.has_key?(changeset.errors, :events) -> changeset
      get_field(changeset, :internal) -> changeset
      match?([_ | _], get_field(changeset, :events)) -> changeset
      true -> add_error(changeset, :events, "can't be blank")
    end
  end

  defp put_secret(changeset) do
    changeset
    |> put_change(:secret, generate_secret())
  end

  defp generate_secret do
    Base.encode16(:crypto.strong_rand_bytes(20))
    |> String.downcase()
  end
end
