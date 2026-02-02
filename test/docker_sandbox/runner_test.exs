defmodule DockerSandbox.RunnerTest do
  use Fnord.TestCase, async: false
  @tag mox: [DockerSandbox.CLI.Mock]

  setup do
    prev = Application.get_env(:fnord, :docker_cli)
    Application.put_env(:fnord, :docker_cli, DockerSandbox.CLI.Mock)

    on_exit(fn ->
      if prev do
        Application.put_env(:fnord, :docker_cli, prev)
      else
        Application.delete_env(:fnord, :docker_cli)
      end
    end)

    :ok
  end

  test "run_container/3 uses strict flags and no mounts and includes image before run_args" do
    image = "test_image"
    run_args = ["--foo", "bar"]

    expect(DockerSandbox.CLI.Mock, :cmd, fn "docker", args, [] ->
      assert "--network=none" in args
      refute Enum.any?(args, &String.starts_with?(&1, "-v"))
      assert image in args

      # ensure image appears before run_args
      assert Enum.find_index(args, &(&1 == image)) < Enum.find_index(args, &(&1 == hd(run_args)))

      {"output", 0}
    end)

    {:ok, out} = DockerSandbox.Runner.run_container(image, run_args, [])
    assert out == "output"
  end

  test "build_image/3 builds from tar context (not host directory)" do
    project_root = Briefly.create!(directory: true)
    File.write!(Path.join(project_root, "hello.txt"), "hello")

    # Provide a fake git executable so build_image prefers `git archive`.
    fakebin = Path.join(project_root, "fakebin")
    File.mkdir_p!(fakebin)

    git_script = Path.join(fakebin, "git")

    File.write!(
      git_script,
      """
      #!/bin/sh
      set -eu
      cmd="$1"
      shift

      if [ "$cmd" = "rev-parse" ] && [ "${1:-}" = "--is-inside-work-tree" ]; then
        echo true
        exit 0
      fi

      if [ "$cmd" = "archive" ]; then
        # Create an empty tarball at the --output path.
        out=""
        for arg in "$@"; do
          case "$arg" in
            --output=*) out="${arg#--output=}" ;;
          esac
        done
        : > "$out"
        exit 0
      fi

      echo "unexpected git args: $cmd $*" 1>&2
      exit 1
      """
    )

    File.chmod!(git_script, 0o755)

    old_path = System.get_env("PATH") || ""
    System.put_env("PATH", fakebin <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
    end)

    # Mock base image ensure to avoid needing a real docker daemon here.
    # We'll do it indirectly by allowing Runner.build_image to call BaseImage.ensure_base_image
    # but intercepting docker calls.
    # BaseImage.ensure_base_image will call docker image inspect, then docker build (base image).
    # Runner.build_image will then call docker build (sandbox image).
    expect(DockerSandbox.CLI.Mock, :cmd, fn "docker", args, [] ->
      assert ["image", "inspect" | _] = args
      {"{}", 1}
    end)

    expect(DockerSandbox.CLI.Mock, :cmd, fn "docker", args, [] ->
      assert "build" in args
      args_text = Enum.join(args, " ")
      assert String.contains?(args_text, "fnord/sandbox-base")
      {"ok", 0}
    end)

    expect(DockerSandbox.CLI.Mock, :cmd, fn "docker", args, [] ->
      assert "build" in args

      # The last arg must be a tar file, not the project_root directory.
      last = List.last(args)
      assert String.ends_with?(last, "context.tar")
      refute last == project_root

      {"ok", 0}
    end)

    res = DockerSandbox.Runner.build_image("demo", "RUN echo hi\n", project_root)
    assert match?({:ok, _tag}, res) or match?({:warning, _}, res)
  end
end
