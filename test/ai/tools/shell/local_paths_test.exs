defmodule AI.Tools.Shell.LocalPathsTest do
  use Fnord.TestCase, async: false

  test "./ script inside project executes (positive path)" do
    project = mock_project("shell-local-positive")

    # create a small shell script under project root
    script_rel = "bin/mybin"

    script_abs = Path.join(project.source_root, script_rel)
    File.mkdir_p!(Path.dirname(script_abs))
    File.write!(script_abs, "#!/bin/sh\necho local-hit\n")

    # Ensure executable
    File.chmod!(script_abs, 0o700)

    args = %{
      "description" => "Run local script",
      "operator" => "&&",
      "commands" => [%{"command" => "./#{script_rel}", "args" => []}]
    }

    assert {:ok, out} = AI.Tools.Shell.call(args)
    assert String.contains?(out, "local-hit")
  end

  test "slash without leading ./ is rejected" do
    _project = mock_project("shell-local-negative")

    args = %{
      "description" => "Reject non-./ slash path",
      "operator" => "&&",
      "commands" => [%{"command" => "scripts/foo", "args" => []}]
    }

    assert {:error, msg} = AI.Tools.Shell.call(args)
    assert msg =~ "Command not found"
  end

  test "symlink that resolves outside project is rejected" do
    project = mock_project("shell-local-symlink")

    # create an outside temp dir with an executable
    outside = Briefly.create!(directory: true)
    evil = Path.join(outside, "evilbin")
    File.write!(evil, "#!/bin/sh\necho outside\n")
    File.chmod!(evil, 0o700)

    # create a symlink inside project that points to the outside path
    link_rel = "link-outside"
    link_abs = Path.join(project.source_root, link_rel)
    File.ln_s!(evil, link_abs)

    args = %{
      "description" => "Symlink escape should be rejected",
      "operator" => "&&",
      "commands" => [%{"command" => "./#{link_rel}", "args" => []}]
    }

    assert {:error, msg} = AI.Tools.Shell.call(args)
    assert msg =~ "Command not found"
  end
end
