defmodule AI.Tools.ShellTest do
  use Fnord.TestCase, async: false
  alias AI.Tools.Shell

  setup do
    # Mock the approvals service to avoid GenServer issues
    try do
      :meck.unload(Services.Approvals)
    rescue
      _ -> :ok
    end

    :meck.new(Services.Approvals, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(Services.Approvals)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  @complex_commands [
    {"pipe", "echo hello | grep test"},
    {"logical-and (&&)", "ls && echo done"},
    {"semicolon", "echo hi; pwd"},
    {"redirection", "echo hi > /dev/null"},
    {"backticks", "echo `ls -la`"},
    {"substitution", "echo $(echo hi)"}
  ]

  describe "call/1 handles complex commands" do
    for {label, command} <- @complex_commands do
      @tag command: command
      test "#{label} requires manual approval", %{command: command} do
        # Mock approval service to approve complex commands
        :meck.expect(Services.Approvals, :confirm, fn opts ->
          # Verify it's asking for approval with the right parameters
          assert Keyword.get(opts, :tag) == "shell_cmd"
          # Complex commands can't be pre-approved
          assert Keyword.get(opts, :persistent) == false
          assert Keyword.get(opts, :subject) == command
          {:ok, :approved}
        end)

        args = %{"description" => "test", "command" => command}

        # Complex commands should execute after manual approval
        assert {:ok, result} = Shell.call(args)
        assert result =~ "Command: `#{command}`"
      end
    end
  end

  test "simple commands work without approval when pre-approved" do
    # Mock to ensure confirm is NOT called for pre-approved commands
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      flunk("confirm should NOT be called for pre-approved commands")
    end)

    # Test a simple pre-approved command
    assert {:ok, result} = Shell.call(%{"description" => "test", "command" => "pwd"})
    assert result =~ "Command: `pwd`"
  end

  test "simple commands require approval when not pre-approved" do
    # Mock approval for non-pre-approved simple commands
    :meck.expect(Services.Approvals, :confirm, fn opts ->
      assert Keyword.get(opts, :tag) == "shell_cmd"
      # Simple commands can be pre-approved
      assert Keyword.get(opts, :persistent) == true
      {:ok, :approved}
    end)

    # Test a simple command that's not pre-approved
    assert {:ok, result} = Shell.call(%{"description" => "test", "command" => "nonexistent_cmd"})
    assert result =~ "Command: `nonexistent_cmd`"
  end

  describe "security vulnerability tests" do
    test "shell injection via semicolon bypass" do
      # Mock to ensure this is treated as complex (should require manual approval)
      :meck.expect(Services.Approvals, :confirm, fn opts ->
        # This SHOULD be flagged as complex and require manual approval
        assert Keyword.get(opts, :persistent) == false,
               "Semicolon commands should not be pre-approvable"

        {:ok, :approved}
      end)

      # This should be detected as complex due to semicolon
      malicious_cmd = "ls; rm -rf /tmp/test"
      assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => malicious_cmd})
    end

    test "command substitution should be detected as complex" do
      # Mock to ensure this is treated as complex
      :meck.expect(Services.Approvals, :confirm, fn opts ->
        assert Keyword.get(opts, :persistent) == false,
               "Command substitution should not be pre-approvable"

        {:ok, :approved}
      end)

      # Test command substitution with $()
      cmd_with_substitution = "cat $(echo /etc/passwd)"

      assert {:ok, _result} =
               Shell.call(%{"description" => "test", "command" => cmd_with_substitution})

      # Test command substitution with backticks
      cmd_with_backticks = "cat `echo /etc/passwd`"

      assert {:ok, _result} =
               Shell.call(%{"description" => "test", "command" => cmd_with_backticks})
    end

    test "pipe should be detected as complex" do
      :meck.expect(Services.Approvals, :confirm, fn opts ->
        assert Keyword.get(opts, :persistent) == false,
               "Pipe commands should not be pre-approvable"

        {:ok, :approved}
      end)

      pipe_cmd = "cat /etc/passwd | grep root"
      assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => pipe_cmd})
    end

    test "redirect operators should be detected as complex" do
      :meck.expect(Services.Approvals, :confirm, fn opts ->
        assert Keyword.get(opts, :persistent) == false,
               "Redirect commands should not be pre-approvable"

        {:ok, :approved}
      end)

      # Test output redirect
      redirect_cmd = "echo 'test' > /tmp/output"
      assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => redirect_cmd})

      # Test input redirect
      input_redirect = "cat < /etc/passwd"
      assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => input_redirect})

      # Test append redirect
      append_cmd = "echo 'more' >> /tmp/output"
      assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => append_cmd})
    end

    test "logical operators should be detected as complex" do
      :meck.expect(Services.Approvals, :confirm, fn opts ->
        assert Keyword.get(opts, :persistent) == false,
               "Logical operators should not be pre-approvable"

        {:ok, :approved}
      end)

      # Test AND operator
      and_cmd = "ls && echo 'success'"
      assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => and_cmd})

      # Test OR operator
      or_cmd = "ls || echo 'failed'"
      assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => or_cmd})
    end

    test "background process operator should be detected as complex" do
      :meck.expect(Services.Approvals, :confirm, fn opts ->
        assert Keyword.get(opts, :persistent) == false,
               "Background processes should not be pre-approvable"

        {:ok, :approved}
      end)

      background_cmd = "sleep 1 &"
      assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => background_cmd})
    end

    test "quoted arguments with spaces should be handled safely" do
      # Mock for a simple command that should be pre-approvable
      :meck.expect(Services.Approvals, :confirm, fn _ ->
        flunk("Simple quoted commands should not require approval if pre-approved")
      end)

      # Use 'ls' which is in the allowed list, with quoted arguments containing spaces
      quoted_cmd = "ls '/tmp/file with spaces'"
      assert {:ok, result} = Shell.call(%{"description" => "test", "command" => quoted_cmd})
      assert result =~ "Command: `ls '/tmp/file with spaces'`"
    end

    test "potential operator bypass attempts" do
      # Test edge cases that might bypass operator detection
      test_cases = [
        # Unicode lookalikes (these should still be caught if they contain actual operators)
        # Still has real semicolon
        "echo 'test'; echo 'bypass'",
        # Still has real command substitution
        "echo test$(echo hidden)",
        # Still has real pipe
        "echo test | grep hidden"
      ]

      for test_cmd <- test_cases do
        :meck.expect(Services.Approvals, :confirm, fn opts ->
          assert Keyword.get(opts, :persistent) == false,
                 "Potentially dangerous command '#{test_cmd}' should not be pre-approvable"

          {:ok, :approved}
        end)

        assert {:ok, _result} = Shell.call(%{"description" => "test", "command" => test_cmd})
      end
    end

    test "stdin redirect behavior with complex commands" do
      # Test that commands with existing input handling don't get double redirects
      :meck.expect(Services.Approvals, :confirm, fn opts ->
        assert Keyword.get(opts, :persistent) == false
        {:ok, :approved}
      end)

      # Command with existing input redirect - should not get < /dev/null appended
      cmd_with_input = "cat < /etc/passwd"
      assert {:ok, result} = Shell.call(%{"description" => "test", "command" => cmd_with_input})
      # Should not have double input redirect
      refute result =~ "< /dev/null"

      # Command with pipe - should not get < /dev/null appended
      pipe_cmd = "echo test | cat"
      assert {:ok, result} = Shell.call(%{"description" => "test", "command" => pipe_cmd})
      refute result =~ "< /dev/null"
    end
  end
end
