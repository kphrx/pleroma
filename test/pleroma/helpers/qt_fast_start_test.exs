# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.QtFastStartTest do
  use ExUnit.Case, async: true
  alias Pleroma.Helpers.QtFastStart

  # Synthetic files: every chunk is a 4-byte marker, and the moov holds an
  # stco (or co64) table pointing at the markers. After the fix, the table
  # must still point at the same markers, in the same order.

  defp atom(type, payload), do: <<byte_size(payload) + 8::32, type::binary, payload::binary>>

  defp mdat(markers), do: {:mdat, markers}

  defp table(:stco, offsets), do: for(o <- offsets, into: <<>>, do: <<o::32>>)
  defp table(:co64, offsets), do: for(o <- offsets, into: <<>>, do: <<o::64>>)

  defp moov(type, offsets) do
    chunks =
      atom(Atom.to_string(type), <<0::32, length(offsets)::32, table(type, offsets)::binary>>)

    atom("moov", atom("trak", atom("mdia", atom("minf", atom("stbl", chunks)))))
  end

  # The file for a layout of :ftyp, :free, :moov and mdat(markers) entries,
  # and the markers in file order.
  defp build(layout, type \\ :stco) do
    ftyp = atom("ftyp", "isom" <> <<0::32>> <> "isommp41")
    free = atom("free", <<0::64>>)
    # the moov size does not depend on the offsets
    moov_size =
      byte_size(moov(type, Enum.flat_map(layout, &markers/1) |> Enum.map(fn _ -> 0 end)))

    {parts, offsets, _} =
      Enum.reduce(layout, {[], [], 0}, fn
        :ftyp, {parts, offsets, pos} ->
          {[ftyp | parts], offsets, pos + byte_size(ftyp)}

        :free, {parts, offsets, pos} ->
          {[free | parts], offsets, pos + byte_size(free)}

        :moov, {parts, offsets, pos} ->
          {[:moov | parts], offsets, pos + moov_size}

        {:mdat, markers}, {parts, offsets, pos} ->
          body = Enum.join(markers)
          starts = for i <- 0..(length(markers) - 1), do: pos + 8 + i * 4
          {[atom("mdat", body) | parts], offsets ++ starts, pos + 8 + byte_size(body)}
      end)

    moov = moov(type, offsets)

    parts
    |> Enum.reverse()
    |> Enum.map(fn
      :moov -> moov
      part -> part
    end)
    |> IO.iodata_to_binary()
  end

  defp markers({:mdat, markers}), do: markers
  defp markers(_), do: []

  defp top_level(<<size::32, type::binary-size(4), rest::binary>>) do
    <<_::binary-size(size - 8), rest::binary>> = rest
    [type | top_level(rest)]
  end

  defp top_level(<<>>), do: []

  # where the chunk table starts, and its entry width in bytes
  defp chunk_table(file) do
    case :binary.match(file, "stco") do
      {pos, _} -> {pos + 8, 4}
      :nomatch -> {elem(:binary.match(file, "co64"), 0) + 8, 8}
    end
  end

  # the bytes each chunk offset points at
  defp pointed(file) do
    {start, width} = chunk_table(file)
    <<_::binary-size(start), count::32, table::binary-size(count * width), _::binary>> = file
    for <<offset::size(width * 8) <- table>>, do: binary_part(file, offset, 4)
  end

  test "moves moov in front of mdat and keeps the chunk offsets right" do
    for layout <- [
          [:ftyp, mdat(~w(AAAA BBBB)), :moov],
          [:ftyp, :free, mdat(~w(AAAA BBBB)), :moov],
          [:ftyp, mdat(~w(AAAA BBBB)), :free, :moov],
          [:ftyp, mdat(~w(AAAA)), :moov, mdat(~w(BBBB CCCC))],
          [:ftyp, mdat(~w(AAAA)), :moov, :free]
        ],
        type <- [:stco, :co64] do
      file = build(layout, type)
      fixed = QtFastStart.fix(file)

      assert ["ftyp", "moov" | _] = top_level(fixed), inspect({layout, type})
      assert pointed(fixed) == pointed(file), inspect({layout, type})
      assert pointed(file) == Enum.flat_map(layout, &markers/1)
    end
  end

  test "drops a free atom only when it sits right after ftyp" do
    assert top_level(QtFastStart.fix(build([:ftyp, :free, mdat(~w(AAAA)), :moov]))) ==
             ~w(ftyp moov mdat)

    assert top_level(QtFastStart.fix(build([:ftyp, mdat(~w(AAAA)), :free, :moov]))) ==
             ~w(ftyp moov mdat free)
  end

  test "leaves fast-start files and other data alone" do
    fast = QtFastStart.fix(build([:ftyp, mdat(~w(AAAA)), :moov]))
    assert QtFastStart.fix(fast) == fast
    assert QtFastStart.fix("not a video") == "not a video"
  end
end
