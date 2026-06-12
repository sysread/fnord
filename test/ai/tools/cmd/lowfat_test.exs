defmodule AI.Tools.Cmd.LowfatTest do
  # Sync: prepends a stub directory to the real PATH - System.find_executable
  # and the spawned shell both read the real OS environment, so tree-scoped
  # overrides cannot stand in for it.
  use Fnord.TestCase, async: false

  # These tests install a fake `lowfat` on PATH that prints a marker line
  # ("LOWFAT_STUB:<argv>") and then execs the wrapped command, so we can assert
  # both *whether* lowfat was invoked and that the wrapped command's exit code
  # propagates through it.
  #
  # The suite disables lowfat by default (FNORD_NO_LOWFAT=1, set in
  # Fnord.TestCase); each test here opts back in by clearing it.

  @marker "LOWFAT_STUB:"

  setup do
    # Opt back into lowfat wrapping for this module.
    System.delete_env("FNORD_NO_LOWFAT")
    on_exit(fn -> Util.Env.put_env("FNORD_NO_LOWFAT", "1") end)

    # Stub `lowfat` on a tmp dir prepended to PATH. The stub echoes its argv,
    # then execs it so the real command runs and its exit status is preserved.
    {:ok, bin_dir} = tmpdir()
    stub = Path.join(bin_dir, "lowfat")

    File.write!(stub, """
    #!/bin/sh
    echo "#{@marker}$*"
    exec "$@"
    """)

    File.chmod!(stub, 0o755)

    original_path = System.get_env("PATH")
    Util.Env.put_env("PATH", "#{bin_dir}:#{original_path}")
    on_exit(fn -> Util.Env.put_env("PATH", original_path) end)

    :ok
  end

  # NOTE: a sole `echo <msg>` is short-circuited to the notify tool (see
  # run_as_shell_commands/5) and never reaches the executor, so these tests use
  # `cat` to exercise the real wrap path.
  test "wraps a sole command with lowfat" do
    project = mock_project("lowfat-sole")
    mock_source_file(project, "greeting.txt", "hi\n")

    args = %{
      "description" => "sole command is wrapped",
      "operator" => "&&",
      "commands" => [%{"command" => "cat", "args" => ["greeting.txt"]}]
    }

    assert {:ok, out} = AI.Tools.Cmd.call(args)
    assert out =~ @marker
    assert out =~ "hi"
  end

  test "wraps every step of an && sequence" do
    mock_project("lowfat-andand")

    args = %{
      "description" => "each && step is wrapped",
      "operator" => "&&",
      "commands" => [
        %{"command" => "echo", "args" => ["one"]},
        %{"command" => "echo", "args" => ["two"]}
      ]
    }

    assert {:ok, out} = AI.Tools.Cmd.call(args)
    assert out =~ "one"
    assert out =~ "two"
    # Both steps wrapped -> two marker lines.
    assert length(String.split(out, @marker)) - 1 == 2
  end

  test "does not wrap stages of a | pipeline" do
    project = mock_project("lowfat-pipe")
    mock_source_file(project, "file.txt", "a\nb\nc\n")

    args = %{
      "description" => "pipe stages must stay raw",
      "operator" => "|",
      "commands" => [
        %{"command" => "cat", "args" => ["file.txt"]},
        %{"command" => "wc", "args" => ["-l"]}
      ]
    }

    assert {:ok, out} = AI.Tools.Cmd.call(args)
    refute out =~ @marker
    assert out |> String.trim() |> String.split() |> hd() == "3"
  end

  test "propagates the wrapped command's non-zero exit code" do
    project = mock_project("lowfat-exit")
    mock_source_file(project, "data.txt", "no match here\n")

    args = %{
      "description" => "exit code survives the lowfat wrapper",
      "operator" => "&&",
      "commands" => [%{"command" => "grep", "args" => ["-q", "pattern", "data.txt"]}]
    }

    assert {:ok, out} = AI.Tools.Cmd.call(args)
    assert out =~ @marker
    assert out =~ "Exit status: 1"
  end

  test "FNORD_NO_LOWFAT disables wrapping even when lowfat is on PATH" do
    project = mock_project("lowfat-killswitch")
    mock_source_file(project, "greeting.txt", "hi\n")
    Util.Env.put_env("FNORD_NO_LOWFAT", "1")

    args = %{
      "description" => "kill switch wins",
      "operator" => "&&",
      "commands" => [%{"command" => "cat", "args" => ["greeting.txt"]}]
    }

    assert {:ok, out} = AI.Tools.Cmd.call(args)
    refute out =~ @marker
    assert out =~ "hi"
  end

  test "does not double-wrap when the model invokes lowfat directly" do
    mock_project("lowfat-double")

    args = %{
      "description" => "model-invoked lowfat is left alone",
      "operator" => "&&",
      "commands" => [%{"command" => "lowfat", "args" => ["echo", "hi"]}]
    }

    assert {:ok, out} = AI.Tools.Cmd.call(args)
    # Exactly one marker: the stub ran once, not lowfat-wrapping-lowfat.
    assert length(String.split(out, @marker)) - 1 == 1
    assert out =~ "hi"
  end
end
