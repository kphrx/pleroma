# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Search.ParadeDB do
  @behaviour Pleroma.Search.SearchBackend

  require Logger
  require Pleroma.Constants

  import Ecto.Query

  import Pleroma.Search.DatabaseSearch,
    only: [
      maybe_fetch: 3,
      maybe_restrict_author: 2,
      maybe_restrict_blocked: 2,
      maybe_restrict_local: 2
    ]

  import Pleroma.Search.Meilisearch, only: [object_to_search_data: 1]

  alias Pleroma.Activity
  alias Pleroma.Config.Getting, as: Config

  @max_limit 40
  @default_table "pleroma_search_documents"

  defp client_impl do
    Config.get([Pleroma.Search.ParadeDB, :client_impl]) ||
      Pleroma.Search.ParadeDB.Client.Postgres
  end

  defp table do
    Config.get([Pleroma.Search.ParadeDB, :table], @default_table)
  end

  @impl true
  def create_index do
    with {:ok, _} <- client_impl().query("CREATE EXTENSION IF NOT EXISTS pg_search", []),
         {:ok, _} <- client_impl().query(create_table_sql(table()), []),
         {:ok, _} <- client_impl().query(create_object_id_index_sql(table()), []),
         {:ok, _} <- client_impl().query(create_bm25_index_sql(table()), []) do
      :ok
    else
      {:error, error} ->
        Logger.error("ParadeDB create_index failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl true
  def drop_index do
    with {:ok, _} <- client_impl().query("DROP TABLE IF EXISTS #{table()}", []) do
      :ok
    else
      {:error, error} ->
        Logger.error("ParadeDB drop_index failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl true
  def healthcheck_endpoints, do: nil

  @impl true
  def add_to_index(activity) do
    maybe_search_data = object_to_search_data(activity.object)

    if activity.data["type"] == "Create" and maybe_search_data do
      dumped_activity_id = dump_activity_id(activity.id)
      actor_ap_id = activity.data["actor"]
      published_at = DateTime.from_unix!(maybe_search_data.published)

      if is_nil(dumped_activity_id) do
        Logger.error("ParadeDB add_to_index failed: invalid activity id #{inspect(activity.id)}")
        :ok
      else
        sql =
          """
          INSERT INTO #{table()} (id, object_id, object_ap_id, actor_ap_id, content, published_at)
          VALUES ($1, $2, $3, $4, $5, $6)
          ON CONFLICT (id) DO UPDATE SET
            object_id = EXCLUDED.object_id,
            object_ap_id = EXCLUDED.object_ap_id,
            actor_ap_id = EXCLUDED.actor_ap_id,
            content = EXCLUDED.content,
            published_at = EXCLUDED.published_at
          """

        params = [
          dumped_activity_id,
          maybe_search_data.id,
          maybe_search_data.ap,
          actor_ap_id,
          maybe_search_data.content,
          published_at
        ]

        case client_impl().query(sql, params) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Logger.error("ParadeDB add_to_index failed: #{inspect(error)}")
            {:error, error}
        end
      end
    else
      :ok
    end
  end

  @impl true
  def remove_from_index(object) do
    sql = "DELETE FROM #{table()} WHERE object_id = $1"

    case client_impl().query(sql, [object.id]) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("ParadeDB remove_from_index failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl true
  def search(user, query, options \\ []) do
    limit = options |> Keyword.get(:limit, @max_limit) |> min(@max_limit)
    offset = Keyword.get(options, :offset, 0)
    author = Keyword.get(options, :author)

    case search_ids(query, limit, offset, author) do
      {:ok, []} ->
        maybe_fetch([], user, query)

      {:ok, ids} ->
        ids
        |> fetch_activities(user, query, author)

      {:error, error} ->
        Logger.error("ParadeDB search failed: #{inspect(error)}")
        maybe_fetch([], user, query)
    end
  end

  defp fetch_activities(ids, user, query, author) do
    dumped_ids =
      ids
      |> Enum.map(&dump_activity_id/1)
      |> Enum.reject(&is_nil/1)

    from(a in Activity, where: a.id in ^dumped_ids)
    |> Activity.with_preloaded_object()
    |> Activity.restrict_deactivated_users()
    |> maybe_restrict_public(user)
    |> maybe_restrict_local(user)
    |> maybe_restrict_author(author)
    |> maybe_restrict_blocked(user)
    |> order_by(
      [a],
      fragment(
        "array_position(?, ?)",
        ^dumped_ids,
        a.id
      )
    )
    |> Pleroma.Repo.all()
    |> maybe_fetch(user, query)
  end

  defp maybe_restrict_public(query, %Pleroma.User{}) do
    intended_recipients = [
      Pleroma.Constants.as_public(),
      Pleroma.Web.ActivityPub.Utils.as_local_public()
    ]

    from(a in query,
      where: fragment("?->>'type' = 'Create'", a.data),
      where: fragment("? && ?", ^intended_recipients, a.recipients)
    )
  end

  defp maybe_restrict_public(query, _user) do
    from(a in query,
      where: fragment("?->>'type' = 'Create'", a.data),
      where: ^Pleroma.Constants.as_public() in a.recipients
    )
  end

  defp search_ids(query, limit, offset, author) do
    base_sql = "SELECT id FROM #{table()} WHERE content &&& $1"
    params = [query]

    {base_sql, params} =
      case author do
        %Pleroma.User{ap_id: ap_id} when is_binary(ap_id) ->
          {base_sql <> " AND actor_ap_id = $2", params ++ [ap_id]}

        _ ->
          {base_sql, params}
      end

    limit_arg = length(params) + 1
    offset_arg = length(params) + 2

    sql =
      base_sql <>
        " ORDER BY published_at DESC, id DESC LIMIT $#{limit_arg} OFFSET $#{offset_arg}"

    params = params ++ [limit, offset]

    with {:ok, %{rows: rows}} <- client_impl().query(sql, params) do
      {:ok, Enum.map(rows, fn [id] -> id end)}
    end
  end

  defp create_table_sql(table) do
    """
    CREATE TABLE IF NOT EXISTS #{table} (
      id uuid PRIMARY KEY,
      object_id bigint NOT NULL,
      object_ap_id text NOT NULL,
      actor_ap_id text,
      content text NOT NULL,
      published_at timestamptz
    )
    """
  end

  defp create_object_id_index_sql(table) do
    "CREATE INDEX IF NOT EXISTS #{table}_object_id_idx ON #{table} (object_id)"
  end

  defp create_bm25_index_sql(table) do
    """
    CREATE INDEX IF NOT EXISTS #{table}_bm25_idx ON #{table}
    USING bm25 (id, content, (actor_ap_id::pdb.literal), published_at)
    WITH (key_field = 'id')
    """
  end

  defp dump_activity_id(<<_::binary-size(16)>> = uuid), do: uuid

  defp dump_activity_id(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, <<_::binary-size(16)>> = uuid} ->
        uuid

      :error ->
        dump_flake_activity_id(id)
    end
  end

  defp dump_activity_id(_), do: nil

  defp dump_flake_activity_id(id) do
    case FlakeId.Ecto.CompatType.dump(id) do
      {:ok, <<_::binary-size(16)>> = uuid} -> uuid
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
