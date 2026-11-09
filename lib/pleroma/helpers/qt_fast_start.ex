# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.QtFastStart do
  @moduledoc """
  Converts a "slow start" (data before metadata) MP4/MOV file to a "fast start" one
  (metadata before data) by relocating the moov atom before the mdat atom and updating
  chunk offset references in stco/co64 atoms accordingly.
  """

  def fix(<<size::integer-big-size(32), 0x66, 0x74, 0x79, 0x70, _::bits>> = binary)
      when size >= 8 do
    index = fix(binary, 0, nil, nil, [])

    case index do
      :abort ->
        binary

      [{"ftyp", _, _, _, _}, {"mdat", _, _, _, _} | _] ->
        faststart(index)

      [{"ftyp", _, _, _, _}, {"free", _, _, _, _}, {"mdat", _, _, _, _} | _] ->
        faststart(index)

      _ ->
        binary
    end
  end

  def fix(binary), do: binary

  # MOOV have been seen before MDAT- abort
  defp fix(<<_::bits>>, _, true, false, _) do
    :abort
  end

  defp fix(
         <<size::integer-big-size(32), fourcc::bits-size(32), rest::bits>>,
         pos,
         got_moov,
         got_mdat,
         acc
       ) do
    try do
      full_size = (size - 8) * 8
      <<data::bits-size(full_size), rest::bits>> = rest

      acc = [
        {fourcc, pos, pos + size, size,
         <<size::integer-big-size(32), fourcc::bits-size(32), data::bits>>}
        | acc
      ]

      fix(rest, pos + size, got_moov || fourcc == "moov", got_mdat || fourcc == "mdat", acc)
    rescue
      _ ->
        :abort
    end
  end

  defp fix(<<>>, _pos, _, _, acc) do
    :lists.reverse(acc)
  end

  defp faststart(index) do
    {{_ftyp, _, _, _, ftyp}, index} = List.keytake(index, "ftyp", 0)

    # Skip re-writing the free fourcc as it's kind of useless.
    # Why stream useless bytes when you can do without?
    {free_size, index} =
      case List.keytake(index, "free", 0) do
        {{_, _, _, size, _}, index} -> {size, index}
        _ -> {0, index}
      end

    {{_moov, _, _, moov_size, moov}, index} = List.keytake(index, "moov", 0)
    offset = -free_size + moov_size
    rest = Enum.map(index, fn {_, _, _, _, data} -> data end)
    <<moov_head::bits-size(64), moov_data::bits>> = moov
    IO.iodata_to_binary([ftyp, moov_head, fix_moov(moov_data, offset, []), rest])
  end

  defp fix_moov(
         <<size::integer-big-size(32), fourcc::bits-size(32), rest::bits>>,
         offset,
         acc
       ) do
    full_size = (size - 8) * 8
    <<data::bits-size(full_size), rest::bits>> = rest

    data =
      cond do
        fourcc in ["trak", "mdia", "minf", "stbl"] ->
          # Theses contains sto or co64 part
          [<<size::integer-big-size(32), fourcc::bits-size(32)>>, fix_moov(data, offset, [])]

        fourcc in ["stco", "co64"] ->
          # fix the damn thing
          <<version::integer-big-size(32), count::integer-big-size(32), rest::bits>> = data

          entry_size =
            case fourcc do
              "stco" -> 32
              "co64" -> 64
            end

          [
            <<size::integer-big-size(32), fourcc::bits-size(32), version::integer-big-size(32),
              count::integer-big-size(32)>>,
            rewrite_entries(entry_size, offset, rest, [])
          ]

        true ->
          [<<size::integer-big-size(32), fourcc::bits-size(32)>>, data]
      end

    acc = [acc | data]
    fix_moov(rest, offset, acc)
  end

  defp fix_moov(<<>>, _, acc), do: acc

  for size <- [32, 64] do
    defp rewrite_entries(
           unquote(size),
           offset,
           <<pos::integer-big-size(unquote(size)), rest::bits>>,
           acc
         ) do
      rewrite_entries(
        unquote(size),
        offset,
        rest,
        acc ++
          [
            <<pos + offset::integer-big-size(unquote(size))>>
          ]
      )
    end
  end

  defp rewrite_entries(_, _, <<>>, acc), do: acc
end
