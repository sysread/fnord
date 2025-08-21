defmodule AI.Tools.ShellTest do
  use Fnord.TestCase, async: false
  alias AI.Tools.Shell

  @disallowed [
    {"pipe", {"echo", ["hello", "|", "grep", "test"]}},
    {"logical-and (&&)", {"ls", ["&&", "echo"]}},
    {"semicolon", {"echo", ["hi;", "pwd"]}},
    {"redirection", {"echo", ["hi", ">", "file"]}},
    {"backticks", {"echo", ["`ls", "-la`"]}},
    {"substitution", {"echo", ["$(echo", "hi)"]}},
    {"heredoc", {"cat", ["<<EOF", "hello", "EOF"]}}
  ]

  describe "call/1 rejects dangerous syntax" do
    for {label, {cmd, params}} <- @disallowed do
      @tag cmd: cmd, params: params
      test "rejects #{label}", %{cmd: cmd, params: params} do
        args = %{"description" => "test", "command" => cmd, "params" => params}

        # Expect descriptive error, not bare true
        assert {:error, msg} = Shell.call(args)
        assert msg == "Command contains disallowed shell syntax"
      end
    end
  end
end
