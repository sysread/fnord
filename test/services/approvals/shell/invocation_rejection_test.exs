defmodule Services.Approvals.Shell.InvocationRejectionTest do
  use Fnord.TestCase, async: false

  alias Services.Approvals.Shell

  describe "rejects direct shell invocations" do
    test "bash -c 'ls'" do
      cmd = %{"command" => "bash", "args" => ["-c", "ls"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "bash -c"})
      assert reason =~ "shell invocation not allowed"
    end

    test "sh -c 'pwd'" do
      cmd = %{"command" => "sh", "args" => ["-c", "pwd"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "sh -c"})
      assert reason =~ "shell invocation not allowed"
    end

    test "zsh -lc 'echo hi'" do
      cmd = %{"command" => "zsh", "args" => ["-lc", "echo hi"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "zsh -lc"})
      assert reason =~ "shell invocation not allowed"
    end

    test "ksh -c 'date'" do
      cmd = %{"command" => "ksh", "args" => ["-c", "date"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "ksh -c"})
      assert reason =~ "shell invocation not allowed"
    end

    test "dash -c 'whoami'" do
      cmd = %{"command" => "dash", "args" => ["-c", "whoami"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "dash -c"})
      assert reason =~ "shell invocation not allowed"
    end

    test "fish -c 'echo fish'" do
      cmd = %{"command" => "fish", "args" => ["-c", "echo fish"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "fish -c"})
      assert reason =~ "shell invocation not allowed"
    end

    test "bash script.sh" do
      cmd = %{"command" => "bash", "args" => ["script.sh"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "bash script.sh"})
      assert reason =~ "shell invocation not allowed"
    end
  end

  describe "rejects env-based shell invocations" do
    test "env bash -c 'ls'" do
      cmd = %{"command" => "env", "args" => ["bash", "-c", "ls"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "env bash -c"})
      assert reason =~ "shell invocation not allowed"
    end

    test "env FOO=bar zsh -c 'echo $FOO'" do
      cmd = %{"command" => "env", "args" => ["FOO=bar", "zsh", "-c", "echo $FOO"]}
      assert {:denied, reason, _} = Shell.confirm(%{session: []}, {"|", [cmd], "env zsh -c"})
      assert reason =~ "shell invocation not allowed"
    end

    test "env bash script.sh" do
      cmd = %{"command" => "env", "args" => ["bash", "script.sh"]}

      assert {:denied, reason, _} =
               Shell.confirm(%{session: []}, {"|", [cmd], "env bash script.sh"})

      assert reason =~ "shell invocation not allowed"
    end
  end
end
