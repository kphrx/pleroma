# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.PleromaCtlTest do
  use ExUnit.Case, async: false

  @pleroma_ctl Path.expand("../../rel/files/bin/pleroma_ctl", __DIR__)

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "pleroma_ctl_test_#{System.unique_integer([:positive])}")

    release_root = Path.join(tmp_dir, "release")
    bin_dir = Path.join(release_root, "bin")

    File.mkdir_p!(bin_dir)
    File.cp!(@pleroma_ctl, Path.join(bin_dir, "pleroma_ctl"))
    File.chmod!(Path.join(bin_dir, "pleroma_ctl"), 0o755)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir, release_root: release_root, bin_dir: bin_dir}
  end

  test "update downloads branch-scoped latest OTP package", %{
    tmp_dir: tmp_dir,
    bin_dir: bin_dir,
    release_root: release_root
  } do
    stubs_dir = Path.join(tmp_dir, "stubs")
    curl_args_path = Path.join(tmp_dir, "curl.args")
    File.mkdir_p!(stubs_dir)
    write_update_stubs(stubs_dir, curl_args_path, "unused", "glibc")

    update_tmp_dir = Path.join(tmp_dir, "update_tmp")
    File.mkdir_p!(update_tmp_dir)

    {output, status} =
      System.cmd(
        Path.join(bin_dir, "pleroma_ctl"),
        [
          "update",
          "--branch",
          "develop",
          "--flavour",
          "amd64",
          "--tmp-dir",
          update_tmp_dir,
          "--no-rm"
        ],
        env: [{"PATH", stubs_dir <> ":" <> System.get_env("PATH", "")}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert File.exists?(Path.join(release_root, "bin/marker"))

    assert ["-fL", url, "-o", artifact_path] =
             curl_args_path
             |> File.read!()
             |> String.split("\n", trim: true)

    assert url ==
             "https://git.pleroma.social/api/packages/pleroma/generic/pleroma-otp-develop-amd64/latest/pleroma.zip"

    assert artifact_path == Path.join(update_tmp_dir, "pleroma.zip")
  end

  test "update detects stable branch and local flavour", %{
    tmp_dir: tmp_dir,
    bin_dir: bin_dir,
    release_root: release_root
  } do
    stubs_dir = Path.join(tmp_dir, "stubs")
    curl_args_path = Path.join(tmp_dir, "curl.args")
    File.mkdir_p!(stubs_dir)
    write_update_stubs(stubs_dir, curl_args_path, "x86_64", "glibc")
    write_start_erl_data(release_root, "2.10.0")

    {output, status} =
      System.cmd(
        Path.join(bin_dir, "pleroma_ctl"),
        ["update", "--tmp-dir", create_update_tmp_dir(tmp_dir), "--no-rm"],
        env: [{"PATH", stubs_dir <> ":" <> System.get_env("PATH", "")}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert curl_url(curl_args_path) ==
             "https://git.pleroma.social/api/packages/pleroma/generic/pleroma-otp-stable-amd64/latest/pleroma.zip"
  end

  test "update detects develop branch and musl arm flavour", %{
    tmp_dir: tmp_dir,
    bin_dir: bin_dir,
    release_root: release_root
  } do
    stubs_dir = Path.join(tmp_dir, "stubs")
    curl_args_path = Path.join(tmp_dir, "curl.args")
    File.mkdir_p!(stubs_dir)
    write_update_stubs(stubs_dir, curl_args_path, "armv7l", "musl")
    write_start_erl_data(release_root, "2.10.0.develop")

    {output, status} =
      System.cmd(
        Path.join(bin_dir, "pleroma_ctl"),
        ["update", "--tmp-dir", create_update_tmp_dir(tmp_dir), "--no-rm"],
        env: [{"PATH", stubs_dir <> ":" <> System.get_env("PATH", "")}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert curl_url(curl_args_path) ==
             "https://git.pleroma.social/api/packages/pleroma/generic/pleroma-otp-develop-arm-musl/latest/pleroma.zip"
  end

  test "update with zip URL bypasses branch and flavour detection", %{
    tmp_dir: tmp_dir,
    bin_dir: bin_dir,
    release_root: release_root
  } do
    stubs_dir = Path.join(tmp_dir, "stubs")
    curl_args_path = Path.join(tmp_dir, "curl.args")
    File.mkdir_p!(stubs_dir)
    write_update_stubs(stubs_dir, curl_args_path, "unsupported-arch", "unsupported-libc")
    write_start_erl_data(release_root, "2.10.0.custombranch")

    custom_url = "https://example.test/custom.zip"

    {output, status} =
      System.cmd(
        Path.join(bin_dir, "pleroma_ctl"),
        [
          "update",
          "--zip-url",
          custom_url,
          "--tmp-dir",
          create_update_tmp_dir(tmp_dir),
          "--no-rm"
        ],
        env: [{"PATH", stubs_dir <> ":" <> System.get_env("PATH", "")}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert curl_url(curl_args_path) == custom_url
  end

  test "passes arguments with spaces and Elixir string metacharacters", %{
    tmp_dir: tmp_dir,
    bin_dir: bin_dir
  } do
    capture_path = Path.join(tmp_dir, "captured_args")
    eval_path = Path.join(tmp_dir, "pleroma_ctl_eval.exs")

    write_executable(Path.join(bin_dir, "pleroma"), """
    #!/bin/sh
    {
      printf '%s\n' 'defmodule Pleroma.ReleaseTasks do'
      printf '%s\n' '  def run(args), do: File.write!(System.fetch_env!("PLEROMA_CTL_CAPTURE"), :erlang.term_to_binary(args))'
      printf '%s\n' 'end'
      printf '%s\n' "$2"
    } > "$PLEROMA_CTL_EVAL_FILE"

    exec elixir "$PLEROMA_CTL_EVAL_FILE"
    """)

    {output, status} =
      System.cmd(
        Path.join(bin_dir, "pleroma_ctl"),
        [
          "user",
          "",
          "has space",
          ~s(has "quote"),
          ~s(has \\ backslash),
          ~S(#{:not_interpolated})
        ],
        env: [
          {"PLEROMA_CTL_CAPTURE", capture_path},
          {"PLEROMA_CTL_EVAL_FILE", eval_path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert capture_path
           |> File.read!()
           |> :erlang.binary_to_term() == [
             "user",
             "",
             "has space",
             ~s(has "quote"),
             ~s(has \\ backslash),
             ~S(#{:not_interpolated})
           ]
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp write_start_erl_data(release_root, version) do
    releases_dir = Path.join(release_root, "releases")
    File.mkdir_p!(releases_dir)
    File.write!(Path.join(releases_dir, "start_erl.data"), "erts-15.0 #{version}\n")
  end

  defp create_update_tmp_dir(tmp_dir) do
    update_tmp_dir = Path.join(tmp_dir, "update_tmp")
    File.mkdir_p!(update_tmp_dir)
    update_tmp_dir
  end

  defp write_update_stubs(stubs_dir, curl_args_path, arch, libc) do
    write_executable(Path.join(stubs_dir, "curl"), """
    #!/bin/sh
    printf '%s\n' "$@" > "#{curl_args_path}"

    while [ $# -gt 0 ]; do
      case "$1" in
        -o)
          artifact="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    : > "$artifact"
    """)

    write_executable(Path.join(stubs_dir, "unzip"), """
    #!/bin/sh
    while [ $# -gt 0 ]; do
      case "$1" in
        -d)
          dest="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    mkdir -p "$dest/release/bin"
    printf 'marker' > "$dest/release/bin/marker"
    """)

    write_executable(Path.join(stubs_dir, "uname"), """
    #!/bin/sh
    printf '%s\n' '#{arch}'
    """)

    write_executable(Path.join(stubs_dir, "getconf"), getconf_stub(libc))

    write_executable(Path.join(stubs_dir, "ldd"), """
    #!/bin/sh
    printf '%s\n' 'musl libc (mock)'
    """)
  end

  defp getconf_stub("glibc") do
    """
    #!/bin/sh
    printf '%s\n' 'glibc 2.40'
    """
  end

  defp getconf_stub(_libc) do
    """
    #!/bin/sh
    exit 1
    """
  end

  defp curl_url(curl_args_path) do
    ["-fL", url, "-o", _artifact_path] =
      curl_args_path
      |> File.read!()
      |> String.split("\n", trim: true)

    url
  end
end
