# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.KeywordPolicy do
  require Pleroma.Constants

  alias Pleroma.Web.ActivityPub.MRF.Utils

  @moduledoc "Reject or Word-Replace activities with a keyword or regex"

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  defp string_matches?(string, pattern) when is_binary(pattern) do
    String.contains?(string, pattern)
  end

  defp string_matches?(string, %Regex{} = pattern) do
    String.match?(string, pattern)
  end

  defp object_payload(%{} = object) do
    [object["content"], object["summary"], object["name"]]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp check_reject(%{"object" => %{} = object} = activity) do
    with {:ok, _new_object} <-
           Pleroma.Object.Updater.do_with_history(object, fn object ->
             payload = object_payload(object)

             if Enum.any?(Pleroma.Config.get([:mrf_keyword, :reject]), fn pattern ->
                  string_matches?(payload, pattern)
                end) do
               {:reject, "[KeywordPolicy] Matches with rejected keyword"}
             else
               {:ok, activity}
             end
           end) do
      {:ok, activity}
    else
      e -> e
    end
  end

  defp check_ftl_removal(%{"type" => "Create", "to" => to, "object" => %{} = object} = activity) do
    check_keyword = fn object ->
      payload = object_payload(object)

      if Enum.any?(Pleroma.Config.get([:mrf_keyword, :federated_timeline_removal]), fn pattern ->
           string_matches?(payload, pattern)
         end) do
        {:should_delist, nil}
      else
        {:ok, %{}}
      end
    end

    should_delist? = fn object ->
      with {:ok, _} <- Pleroma.Object.Updater.do_with_history(object, check_keyword) do
        false
      else
        _ -> true
      end
    end

    if Pleroma.Constants.as_public() in to and should_delist?.(object) do
      to = List.delete(to, Pleroma.Constants.as_public())
      cc = [Pleroma.Constants.as_public() | activity["cc"] || []]

      activity =
        activity
        |> Map.put("to", to)
        |> Map.put("cc", cc)

      {:ok, activity}
    else
      {:ok, activity}
    end
  end

  defp check_ftl_removal(activity) do
    {:ok, activity}
  end

  defp check_replace(%{"object" => %{} = object} = activity) do
    replace_kw = fn object ->
      ["content", "name", "summary"]
      |> Enum.filter(fn field -> Map.has_key?(object, field) && object[field] end)
      |> Enum.reduce(object, fn field, object ->
        data =
          Enum.reduce(
            Pleroma.Config.get([:mrf_keyword, :replace]),
            object[field],
            fn {pat, repl}, acc -> String.replace(acc, pat, repl) end
          )

        Map.put(object, field, data)
      end)
      |> (fn object -> {:ok, object} end).()
    end

    {:ok, object} = Pleroma.Object.Updater.do_with_history(object, replace_kw)

    activity = Map.put(activity, "object", object)

    {:ok, activity}
  end

  @impl true
  def filter(%{"type" => type, "object" => %{"content" => _content}} = activity)
      when type in ["Create", "Update"] do
    with {:ok, activity} <- check_reject(activity),
         {:ok, activity} <- check_ftl_removal(activity),
         {:ok, activity} <- check_replace(activity) do
      {:ok, activity}
    else
      {:reject, nil} -> {:reject, "[KeywordPolicy] "}
      {:reject, _} = e -> e
      _e -> {:reject, "[KeywordPolicy] "}
    end
  end

  @impl true
  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    mrf_keyword =
      Pleroma.Config.get(:mrf_keyword, [])
      |> Enum.map(fn {key, value} ->
        {key,
         Enum.map(value, fn
           {pattern, replacement} ->
             %{
               "pattern" => Utils.describe_regex_or_string(pattern),
               "replacement" => replacement
             }

           pattern ->
             Utils.describe_regex_or_string(pattern)
         end)}
      end)
      |> Enum.into(%{})

    {:ok, %{mrf_keyword: mrf_keyword}}
  end

  @impl true
  def config_description do
    %{
      key: :mrf_keyword,
      related_policy: "Pleroma.Web.ActivityPub.MRF.KeywordPolicy",
      label: "MRF Keyword",
      description:
        "Reject or Word-Replace activities matching a keyword or [Regex](https://hexdocs.pm/elixir/Regex.html).",
      children: [
        %{
          key: :reject,
          type: {:list, :string},
          description: """
            A list of patterns which result in the activity being rejected.

            Each pattern can be a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.
          """,
          suggestions: ["foo", ~r/foo/iu]
        },
        %{
          key: :federated_timeline_removal,
          type: {:list, :string},
          description: """
            A list of patterns which result in the activity being removed from federated timelines (a.k.a unlisted).

            Each pattern can be a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.
          """,
          suggestions: ["foo", ~r/foo/iu]
        },
        %{
          key: :replace,
          type: {:list, :tuple},
          key_placeholder: "instance",
          value_placeholder: "reason",
          description: """
            **Pattern**: a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.

            **Replacement**: a string. Leaving the field empty is permitted.
          """
        }
      ]
    }
  end
end
