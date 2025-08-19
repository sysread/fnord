defmodule AI.Tools.ShellTest do
  use Fnord.TestCase, async: true
  alias AI.Tools.Shell

  @disallowed [
    {"pipe", "|"},
    {"logical-and (&&)", "ls && echo"},
    {"semicolon", "echo hi; pwd"},
    {"redirection", "echo hi > file"},
    {"backticks", "`ls -la`"},
    {"substitution", "$(echo hi)"},
    {"heredoc", "<<EOF\nhello\nEOF"}
  ]

  describe "call/1 rejects dangerous syntax" do
    for {label, cmd} <- @disallowed do
      @tag cmd: cmd
      test "rejects #{label}", %{cmd: cmd} do
        args = %{"description" => "test", "cmd" => cmd}

        # Expect descriptive error, not bare true
        assert {:error, msg} = Shell.call(args)
        assert msg == "Command contains disallowed shell syntax"
      end
    end
  end
end
