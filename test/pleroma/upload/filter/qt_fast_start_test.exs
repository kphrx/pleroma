# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.QtFastStartTest do
  use Pleroma.DataCase, async: true
  alias Pleroma.Upload.Filter.QtFastStart

  test "leaves a fast-start video unchanged" do
    upload = %Pleroma.Upload{
      name: "video.mp4",
      content_type: "video/mp4",
      path: Path.absname("test/fixtures/video.mp4"),
      tempfile: Path.absname("test/fixtures/video.mp4")
    }

    assert {:ok, :noop} = QtFastStart.filter(upload)
  end

  test "converts a slow-start video to fast-start" do
    File.cp!(
      "test/fixtures/video_slow_start.mp4",
      "test/fixtures/video_slow_start_tmp.mp4"
    )

    upload = %Pleroma.Upload{
      name: "video_slow_start.mp4",
      content_type: "video/mp4",
      path: Path.absname("test/fixtures/video_slow_start_tmp.mp4"),
      tempfile: Path.absname("test/fixtures/video_slow_start_tmp.mp4")
    }

    assert {:ok, :filtered} = QtFastStart.filter(upload)

    fixed = File.read!("test/fixtures/video_slow_start_tmp.mp4")
    <<atom_size::integer-big-size(32), fc1::bits-size(32), rest::bits>> = fixed
    assert fc1 == "ftyp"
    payload_size = (atom_size - 8) * 8
    <<_payload::bits-size(payload_size), rest::bits>> = rest
    <<_s2::integer-big-size(32), fc2::bits-size(32), _::bits>> = rest
    assert fc2 == "moov"
  end

  test "noop for non-video content" do
    upload = %Pleroma.Upload{
      name: "image.jpg",
      content_type: "image/jpeg",
      path: Path.absname("test/fixtures/image.jpg"),
      tempfile: Path.absname("test/fixtures/image.jpg")
    }

    assert {:ok, :noop} = QtFastStart.filter(upload)
  end
end
