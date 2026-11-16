# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.QtFastStartTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Pleroma.Upload.Filter.QtFastStart

  defp upload(path, content_type \\ "video/mp4") do
    %Pleroma.Upload{
      name: Path.basename(path),
      content_type: content_type,
      path: path,
      tempfile: path
    }
  end

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "qt_fast_start_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp copy(fixture, tmp_dir) do
    path = Path.join(tmp_dir, Path.basename(fixture))
    File.cp!(fixture, path)
    path
  end

  test "leaves a fast-start video unchanged" do
    assert {:ok, :noop} = QtFastStart.filter(upload(Path.absname("test/fixtures/video.mp4")))
  end

  test "converts a slow-start video to fast-start", %{tmp_dir: tmp_dir} do
    path = copy("test/fixtures/video_slow_start.mp4", tmp_dir)

    assert {:ok, :filtered} = QtFastStart.filter(upload(path))

    fixed = File.read!(path)
    <<atom_size::integer-big-size(32), fc1::bits-size(32), rest::bits>> = fixed
    assert fc1 == "ftyp"
    payload_size = (atom_size - 8) * 8
    <<_payload::bits-size(payload_size), rest::bits>> = rest
    <<_s2::integer-big-size(32), fc2::bits-size(32), _::bits>> = rest
    assert fc2 == "moov"
  end

  test "noop for non-video content" do
    upload = upload(Path.absname("test/fixtures/image.jpg"), "image/jpeg")
    assert {:ok, :noop} = QtFastStart.filter(upload)
  end

  test "noop with a warning when the file cannot be read", %{tmp_dir: tmp_dir} do
    log =
      capture_log(fn ->
        assert {:ok, :noop} = QtFastStart.filter(upload(Path.join(tmp_dir, "missing.mp4")))
      end)

    assert log =~ "QtFastStart"
  end
end
