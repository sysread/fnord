defmodule AI.Tools.Shell.InvocationTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("shell-invocation-test")
    {:ok, project: project}
  end

  test "denies direct shell invocation attempts" do
    args = %{
      "description" => "Attempt to invoke a shell",
      "operator" => "&&",
      "commands" => [
        %{"command" => "bash", "args" => ["-c", "echo hi"]}
      ]
    }

    assert {:denied, reason} = AI.Tools.Shell.call(args)
    assert reason =~ "Execute commands directly; do not invoke through a shell"
  end

  test "does not treat version checks as disallowed shell invocation" do
    args = %{
      "description" => "Version check should not be caught by shell-invocation detector",
      "operator" => "&&",
      "commands" => [
        %{"command" => "bash", "args" => ["--version"]}
      ]
    }

    case AI.Tools.Shell.call(args) do
      {:denied, reason} ->
        # If denied, ensure the denial is not from the shell-invocation shortcut
        refute reason =~ "Execute commands directly; do not invoke through a shell"

      _other ->
        # ok — some other outcome (approved, error, etc.) is acceptable for this test
        assert true
    end
  end
end
