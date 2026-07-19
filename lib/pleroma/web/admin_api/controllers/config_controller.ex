# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.AdminAPI.ConfigController do
  use Pleroma.Web, :controller

  alias Pleroma.Config
  alias Pleroma.ConfigDB
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  plug(Pleroma.Web.ApiSpec.CastAndValidate, replace_params: false)
  plug(OAuthScopesPlug, %{scopes: ["admin:write"]} when action == :update)

  plug(
    OAuthScopesPlug,
    %{scopes: ["admin:read"]}
    when action in [:show, :descriptions]
  )

  action_fallback(Pleroma.Web.AdminAPI.FallbackController)

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.Admin.ConfigOperation

  defp translate_descriptions(descriptions, path \\ []) do
    Enum.map(descriptions, fn desc -> translate_item(desc, path) end)
  end

  defp translate_string(str, path, type) do
    Gettext.dpgettext(
      Pleroma.Web.Gettext,
      "config_descriptions",
      Pleroma.Docs.Translator.Compiler.msgctxt_for(path, type),
      str
    )
  end

  defp maybe_put_translated(item, key, path) do
    if item[key] do
      Map.put(
        item,
        key,
        translate_string(
          item[key],
          path ++ [Pleroma.Docs.Translator.Compiler.key_for(item)],
          to_string(key)
        )
      )
    else
      item
    end
  end

  defp translate_item(item, path) do
    item
    |> maybe_put_translated(:label, path)
    |> maybe_put_translated(:description, path)
    |> translate_children(path)
  end

  defp translate_children(%{children: children} = item, path) when is_list(children) do
    item
    |> Map.put(
      :children,
      translate_descriptions(children, path ++ [Pleroma.Docs.Translator.Compiler.key_for(item)])
    )
  end

  defp translate_children(item, _path) do
    item
  end

  def descriptions(conn, _params) do
    descriptions =
      Pleroma.Docs.JSON.compiled_descriptions()
      |> Enum.filter(&allowed_config?(&1, :whitelist))
      |> Enum.reject(&allowed_config?(&1, :blacklist))

    json(conn, translate_descriptions(descriptions))
  end

  def show(%{private: %{open_api_spex: %{params: %{only_db: true}}}} = conn, _) do
    with :ok <- configurable_from_database() do
      configs = Pleroma.Repo.all(ConfigDB)

      render(conn, "index.json", %{
        configs: configs,
        need_reboot: Restarter.Pleroma.need_reboot?()
      })
    end
  end

  def show(conn, _params) do
    with :ok <- configurable_from_database() do
      configs = ConfigDB.get_all_as_keyword()

      merged =
        Config.Holder.default_config()
        |> ConfigDB.merge(configs)
        |> Enum.map(fn {group, values} ->
          Enum.map(values, fn {key, value} ->
            db =
              if configs[group][key] do
                ConfigDB.get_db_keys(configs[group][key], key)
              end

            db_value = configs[group][key]

            merged_value =
              if not is_nil(db_value) and Keyword.keyword?(db_value) and
                   ConfigDB.sub_key_full_update?(group, key, Keyword.keys(db_value)) do
                ConfigDB.merge_group(group, key, value, db_value)
              else
                value
              end

            %ConfigDB{
              group: group,
              key: key,
              value: merged_value
            }
            |> Pleroma.Maps.put_if_present(:db, db)
          end)
        end)
        |> List.flatten()

      render(conn, "index.json", %{
        configs: merged,
        need_reboot: Restarter.Pleroma.need_reboot?()
      })
    end
  end

  def update(%{private: %{open_api_spex: %{body_params: %{configs: configs}}}} = conn, _) do
    with :ok <- configurable_from_database() do
      results =
        configs
        |> Enum.filter(&allowed_config?(&1, :whitelist))
        |> Enum.reject(&allowed_config?(&1, :blacklist))
        |> Enum.map(fn
          %{group: group, key: key, delete: true} = params ->
            ConfigDB.delete(%{group: group, key: key, subkeys: params[:subkeys]})

          %{group: group, key: key, value: value} ->
            ConfigDB.update_or_create(%{group: group, key: key, value: value})
        end)
        |> Enum.reject(fn {result, _} -> result == :error end)

      {deleted, updated} =
        results
        |> Enum.map(fn {:ok, %{key: key, value: value} = config} ->
          Map.put(config, :db, ConfigDB.get_db_keys(value, key))
        end)
        |> Enum.split_with(&(Ecto.get_meta(&1, :state) == :deleted))

      Config.TransferTask.load_and_update_env(deleted, false)

      if not Restarter.Pleroma.need_reboot?() do
        changed_reboot_settings? =
          (updated ++ deleted)
          |> Enum.any?(&Config.TransferTask.pleroma_need_restart?(&1.group, &1.key, &1.value))

        if changed_reboot_settings?, do: Restarter.Pleroma.need_reboot()
      end

      render(conn, "index.json", %{
        configs: updated,
        need_reboot: Restarter.Pleroma.need_reboot?()
      })
    end
  end

  defp configurable_from_database do
    if Config.get(:configurable_from_database) do
      :ok
    else
      {:error, "You must enable configurable_from_database in your config file."}
    end
  end

  defp allowed_config?(":pleroma", ":database_config_whitelist", _), do: true
  defp allowed_config?(":pleroma", ":database_config_blacklist", _), do: true

  defp allowed_config?(group, key, mode) do
    configs = 
      case mode do
        :whitelist -> Config.get(:database_config_whitelist)
        :blacklist -> Config.get(:database_config_blacklist)
    end

    if configs do
      Enum.any?(configs, fn
        {allowed_group} ->
          group == inspect(allowed_group)

        {allowed_group, allowed_key} ->
          group == inspect(allowed_group) && key == inspect(allowed_key)
      end)
    else
      true
    end
  end

  defp allowed_config?(%{group: group, key: key}, mode) do
    allowed_config?(group, key, mode)
  end

  defp allowed_config?(%{group: group} = config, mode) do
    allowed_config?(group, config[:key], mode)
  end
end
