defmodule AI.Tools.Shell.BasicsTest do
  use Fnord.TestCase, async: false

  test "preapproved pipeline: cat -> wc -l counts lines in files" do
    project = mock_project("shell-preapproved")
    mock_source_file(project, "file1.txt", "hello\n")
    mock_source_file(project, "file2.txt", "world\n")

    args = %{
      "description" => "Count lines using preapproved commands",
      "timeout_ms" => 2_000,
      "operator" => "|",
      "commands" => [
        %{"command" => "cat", "args" => ["file1.txt", "file2.txt"]},
        %{"command" => "wc", "args" => ["-l"]}
      ]
    }

    assert {:ok, out} = AI.Tools.Shell.call(args)
    # wc -l prefixes with whitespace and count
    assert out |> String.trim() |> String.split() |> hd() == "2"
  end

  test "stdin runner path: echo -> tr uppercases output" do
    mock_project("shell-stdin")

    args = %{
      "description" => "Uppercase via pipeline using stdin temp runner",
      "timeout_ms" => 2_000,
      "operator" => "|",
      "commands" => [
        %{"command" => "echo", "args" => ["abc"]},
        %{"command" => "tr", "args" => ["a-z", "A-Z"]}
      ]
    }

    assert {:ok, out} = AI.Tools.Shell.call(args)
    assert String.trim(out) == "ABC"
  end

  test "non-zero exit halts pipeline and returns error" do
    project = mock_project("shell-error")
    mock_source_file(project, "data.txt", "no match here\n")

    args = %{
      "description" => "Pipeline should stop on error",
      "timeout_ms" => 2_000,
      "operator" => "|",
      "commands" => [
        # grep -q returns 1 when no match found
        %{"command" => "grep", "args" => ["-q", "pattern", "data.txt"]},
        %{"command" => "wc", "args" => ["-l"]}
      ]
    }

    assert {:ok, msg} = AI.Tools.Shell.call(args)
    assert msg =~ "Exit status: 1"
    assert msg =~ "grep -q \"pattern\" \"data.txt\""
  end

  test "timeout produces error and stops pipeline" do
    mock_project("shell-timeout")

    args = %{
      "description" => "Timeout short to trigger",
      "timeout_ms" => 10,
      "operator" => "|",
      "commands" => [
        %{"command" => "sleep", "args" => ["1"]},
        %{"command" => "echo", "args" => ["done"]}
      ]
    }

    assert {:ok, msg} = AI.Tools.Shell.call(args)

    # run_with_timeout returns {:error, :timeout}, formatted as Exit code: timeout
    assert msg =~ "Error: timed out after"
  end

  test "missing command produces error and stops pipeline" do
    mock_project("shell-missing")

    args = %{
      "description" => "Missing command",
      "operator" => "&&",
      "commands" => [
        %{"command" => "i_sure_hope_this_cmd_does_not_really_exist", "args" => []},
        %{"command" => "echo", "args" => ["done"]}
      ]
    }

    assert {:error, msg} = AI.Tools.Shell.call(args)
    assert msg =~ "Command not found"
  end

  test "special cases that special flower, rg" do
    project = mock_project("rg")

    args = %{
      "description" => "Missing command",
      "operator" => "&&",
      "commands" => [
        %{"command" => "rg", "args" => ["pattern"]}
      ]
    }

    assert {:ok, msg} = AI.Tools.Shell.call(args)
    assert msg =~ ~r/Command: (.+?)\/rg "pattern" "#{Regex.escape(project.source_root)}"/
  end

  test "format_commands and ui notes" do
    args = %{
      "description" => "Describe",
      "operator" => "|",
      "commands" => [
        %{"command" => "ls", "args" => ["-l"]},
        %{"command" => "grep", "args" => ["foo"]}
      ]
    }

    {req_title, req_desc} = AI.Tools.Shell.ui_note_on_request(args)
    assert String.starts_with?(req_title, "shell> ")
    assert req_desc == "Describe"

    {res_title, _res_detail} = AI.Tools.Shell.ui_note_on_result(args, "ok")
    assert String.starts_with?(res_title, "shell> ")
  end

  test "validate_timeout clamps and defaults correctly" do
    mock_project("shell-timeouts")

    # invalid timeout value -> default
    args1 = %{
      "description" => "invalid",
      "timeout_ms" => "oops",
      "operator" => "&&",
      "commands" => [%{"command" => "echo", "args" => ["x"]}]
    }

    assert {:ok, _} = AI.Tools.Shell.call(args1)

    # too large value clamps at max, still should execute fine
    args2 = %{
      "description" => "too large",
      "timeout_ms" => 1_000_000,
      "operator" => "&&",
      "commands" => [%{"command" => "echo", "args" => ["y"]}]
    }

    assert {:ok, _} = AI.Tools.Shell.call(args2)

    # negative value -> default
    args3 = %{
      "description" => "negative",
      "timeout_ms" => -10,
      "operator" => "&&",
      "commands" => [%{"command" => "echo", "args" => ["z"]}]
    }

    assert {:ok, _} = AI.Tools.Shell.call(args3)
  end
end
