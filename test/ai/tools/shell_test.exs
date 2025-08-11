defmodule AI.Tools.ShellTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.Shell

  @valid_desc "Test command description"
  @valid_cmd "ls -l"

  setup do
    # Mock dependencies to prevent network calls and control behavior
    :meck.new(AI.Agent.ShellCmdParser, [:no_link, :passthrough])
    :meck.new(System, [:no_link, :passthrough])
    :meck.new(UI, [:no_link, :passthrough])
    :meck.new(Once, [:no_link, :passthrough])
    :meck.new(Store, [:no_link, :passthrough])

    # CRITICAL: Provide default mock for AI.Agent.ShellCmdParser to prevent network calls
    # Any test that needs different behavior can override this with :meck.expect
    :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn %{shell_cmd: cmd} ->
      # Simple parsing logic to avoid network calls
      parts = String.split(String.trim(cmd), " ", parts: 2)
      main_cmd = List.first(parts) || "unknown"
      args_str = List.last(parts) || ""
      args = if args_str == "", do: [], else: String.split(args_str, " ")
      
      {:ok, %{
        "cmd" => main_cmd,
        "args" => args,
        "approval_bits" => [main_cmd]
      }}
    end)

    on_exit(fn ->
      :meck.unload([AI.Agent.ShellCmdParser, System, UI, Once, Store])
    end)

    {:ok, project: mock_project("shell_test")}
  end

  describe "read_args/1" do
    test "rejects empty or all-whitespace commands" do
      Enum.each(["", " ", "\t", "\n"], fn cmd ->
        result = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd})
        assert match?({:error, _, _}, result), "should reject: #{inspect(cmd)}"
      end)
    end

    test "rejects empty description" do
      result = Shell.read_args(%{"description" => "", "cmd" => "ls"})
      assert match?({:error, _, _}, result), "should reject empty description"
    end

    test "accepts valid commands with proper arguments" do
      result = Shell.read_args(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:ok, %{"description" => @valid_desc, "cmd" => "ls -l"}} = result
    end

    test "trims command whitespace" do
      result = Shell.read_args(%{"description" => @valid_desc, "cmd" => "  ls -l  "})
      assert {:ok, %{"description" => @valid_desc, "cmd" => "ls -l"}} = result
    end

    test "delegates dangerous syntax checking to utility module" do
      # Test that dangerous commands are rejected via the utility module
      result = Shell.read_args(%{"description" => @valid_desc, "cmd" => "ls | grep foo"})
      assert {:error, msg} = result

      assert msg ==
               "Only simple, direct commands are permitted: no pipes, logical operators, redirection, subshells, or command chaining."
    end
  end

  describe "ui_note_on_request/1" do
    test "returns formatted request note" do
      args = %{"cmd" => "git status"}
      {title, body} = Shell.ui_note_on_request(args)
      
      assert title == "Shell"
      assert body == "git status"
    end
  end

  describe "ui_note_on_result/2" do
    test "returns formatted result for short output" do
      args = %{"cmd" => "ls"}
      result = "file1.txt\nfile2.txt"
      
      {title, body} = Shell.ui_note_on_result(args, result)
      
      assert title == "Shell"
      assert body == "$ ls\nfile1.txt\nfile2.txt\n\n"
    end

    test "truncates long output with additional lines indicator" do
      args = %{"cmd" => "find"}
      long_result = Enum.join(1..15 |> Enum.map(&"line#{&1}"), "\n")
      
      {title, body} = Shell.ui_note_on_result(args, long_result)
      
      assert title == "Shell"
      assert body =~ "$ find"
      assert body =~ "line1"
      assert body =~ "line10"
      refute body =~ "line11"
      assert body =~ "...plus 5 additional lines"
    end
  end

  describe "integration with AI.Tools flow" do
    test "proper flow: read_args validates before call is invoked" do
      # Test the correct flow using AI.Tools.perform_tool_call
      toolbox = %{"shell_tool" => Shell}
      
      # This should fail at read_args validation, before call/1 is reached
      result = AI.Tools.perform_tool_call("shell_tool", %{"description" => @valid_desc, "cmd" => "ls | grep foo"}, toolbox)
      assert {:error, "Only simple, direct commands are permitted: no pipes, logical operators, redirection, subshells, or command chaining."} = result
    end

    test "proper flow: valid args go through read_args then call" do
      toolbox = %{"shell_tool" => Shell}
      
      # Mock the AI parser and execution chain
      :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn %{shell_cmd: "ls -l"} ->
        {:ok, %{"cmd" => "ls", "args" => ["-l"], "approval_bits" => ["ls"]}}
      end)
      :meck.expect(Once, :get, fn _ -> {:ok, :approved} end)
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test"}} end)
      :meck.expect(System, :cmd, fn "ls", ["-l"], _ -> {"output", 0} end)
      
      result = AI.Tools.perform_tool_call("shell_tool", %{"description" => @valid_desc, "cmd" => "ls -l"}, toolbox)
      assert {:ok, "output"} = result
    end

    test "call/1 defensive check (should never happen in normal flow)" do
      # This tests the defensive dangerous syntax check in call/1
      # In normal flow, read_args/1 catches this, but call/1 has a redundant check
      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls | grep foo"})
      # The with clause fails at contains_disallowed_syntax and returns the failing value
      assert result == true
    end
  end

  describe "call/1 direct invocation edge cases" do
    test "returns error when description missing" do
      result = Shell.call(%{"cmd" => @valid_cmd})
      assert {:error, :missing_argument, "description"} = result
    end

    test "returns error when cmd missing" do
      result = Shell.call(%{"description" => @valid_desc})
      assert {:error, :missing_argument, "cmd"} = result
    end

    test "returns error when ShellCmdParser fails" do
      :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn _ -> 
        {:error, "Parse failed"}
      end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => @valid_cmd})
      assert {:error, "Parse failed"} = result
    end
  end

  describe "call/1 - approval phase for regular commands" do
    setup do
      # Mock successful parsing
      :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn %{shell_cmd: _} ->
        {:ok, %{
          "cmd" => "ls", 
          "args" => ["-l"], 
          "approval_bits" => ["ls"]
        }}
      end)
      :ok
    end

    test "executes command when user approves with 'You son of a bitch, I'm in'" do
      :meck.expect(Once, :get, fn _ -> {:error, :not_seen} end)
      :meck.expect(UI, :choose, fn _prompt, _options -> "You son of a bitch, I'm in" end)
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test/path"}} end)
      :meck.expect(System, :cmd, fn "ls", ["-l"], [stderr_to_stdout: true, parallelism: true, cd: "/test/path"] ->
        {"file1.txt\nfile2.txt", 0}
      end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:ok, "file1.txt\nfile2.txt"} = result
    end

    test "approves for session when user chooses session approval option" do
      :meck.expect(Once, :get, fn _ -> {:error, :not_seen} end)
      :meck.expect(UI, :choose, fn _prompt, options -> 
        # Simulate user choosing the session approval option
        Enum.find(options, &String.starts_with?(&1, "You son of a... for the whole session:"))
      end)
      :meck.expect(Once, :set, fn "shell_cmd#ls", :approved -> true end)
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test/path"}} end)
      :meck.expect(System, :cmd, fn "ls", ["-l"], _ -> {"output", 0} end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:ok, "output"} = result
      
      # Verify Once.set was called for session approval
      assert :meck.called(Once, :set, ["shell_cmd#ls", :approved])
    end

    test "uses cached approval from Once for subsequent calls" do
      :meck.expect(Once, :get, fn "shell_cmd#ls" -> {:ok, :approved} end)
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test/path"}} end)
      :meck.expect(System, :cmd, fn "ls", ["-l"], _ -> {"cached output", 0} end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:ok, "cached output"} = result
      
      # UI.choose should not be called since we have cached approval
      refute :meck.called(UI, :choose, :_)
    end

    test "returns error when user denies command" do
      :meck.expect(Once, :get, fn _ -> {:error, :not_seen} end)
      :meck.expect(UI, :choose, fn _prompt, _options -> "Deny" end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:error, "The user declined to approve the command."} = result
    end

    test "returns error with feedback when user denies with feedback" do
      :meck.expect(Once, :get, fn _ -> {:error, :not_seen} end)
      :meck.expect(UI, :choose, fn _prompt, _options -> "Deny (with feedback)" end)
      :meck.expect(UI, :prompt, fn _ -> "This seems unnecessary" end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:error, error_msg} = result
      assert error_msg =~ "The user declined to approve the command"
      assert error_msg =~ "This seems unnecessary"
    end
  end

  describe "shell command behavior understanding" do
    test "complex commands are blocked at read_args level" do
      # In the real system, commands with pipes would be rejected by read_args
      # before they ever reach call/1, so the ShellCmdParser converting them
      # to "sh -c ..." format would never happen through normal AI.Tools flow
      toolbox = %{"shell_tool" => Shell}
      result = AI.Tools.perform_tool_call("shell_tool", %{"description" => "Find files", "cmd" => "ls | grep foo"}, toolbox)
      
      assert {:error, "Only simple, direct commands are permitted: no pipes, logical operators, redirection, subshells, or command chaining."} = result
    end

    test "theoretical sh command handling (if it could reach call/1)" do
      # This tests what would happen if a "sh -c ..." command somehow made it through
      # the validation (which it can't in normal flow)
      :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn %{shell_cmd: "sh -c 'ls'"} ->
        {:ok, %{"cmd" => "sh", "args" => ["-c", "ls"], "approval_bits" => ["sh"]}}
      end)
      :meck.expect(UI, :warning_banner, fn _ -> :ok end)
      :meck.expect(UI, :choose, fn _prompt, options -> 
        # For shell commands, session approval is not offered
        refute Enum.any?(options, &String.contains?(&1, "session"))
        "You son of a bitch, I'm in"
      end)
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test/path"}} end)
      :meck.expect(System, :cmd, fn "sh", ["-c", "ls"], _ -> {"output", 0} end)

      # Note: This bypasses read_args validation by calling call/1 directly
      result = Shell.call(%{"description" => "Shell command", "cmd" => "sh -c 'ls'"})
      assert {:ok, "output"} = result
    end
  end

  describe "call/1 - command execution" do
    setup do
      # Mock successful parsing and approval for execution tests
      :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn %{shell_cmd: _} ->
        {:ok, %{"cmd" => "ls", "args" => ["-l"], "approval_bits" => ["ls"]}}
      end)
      :meck.expect(Once, :get, fn _ -> {:ok, :approved} end)
      :ok
    end

    test "uses project source root as working directory when project available" do
      project = %{source_root: "/project/root"}
      :meck.expect(Store, :get_project, fn -> {:ok, project} end)
      :meck.expect(System, :cmd, fn "ls", ["-l"], opts ->
        assert opts[:cd] == "/project/root"
        {"output", 0}
      end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:ok, "output"} = result
    end

    test "falls back to current working directory when no project" do
      current_dir = File.cwd!()
      :meck.expect(Store, :get_project, fn -> {:error, :no_project} end)
      :meck.expect(System, :cmd, fn "ls", ["-l"], opts ->
        assert opts[:cd] == current_dir
        {"output", 0}
      end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:ok, "output"} = result
    end

    test "returns success for zero exit code" do
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test"}} end)
      :meck.expect(System, :cmd, fn _, _, _ -> {"successful output", 0} end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:ok, "successful output"} = result
    end

    test "returns error for non-zero exit code" do
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test"}} end)
      :meck.expect(System, :cmd, fn _, _, _ -> {"error output", 1} end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:error, "error output"} = result
    end

    test "trims trailing whitespace from command output" do
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test"}} end)
      :meck.expect(System, :cmd, fn _, _, _ -> {"output with trailing spaces   \n\n", 0} end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:ok, "output with trailing spaces"} = result
    end

    test "handles ErlangError :enoent (command not found)" do
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test"}} end)
      :meck.expect(System, :cmd, fn _, _, _ -> 
        raise ErlangError, reason: :enoent
      end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:error, "Command not found: ls"} = result
    end

    test "handles ErlangError :eaccess (permission denied)" do
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test"}} end)
      :meck.expect(System, :cmd, fn _, _, _ -> 
        raise ErlangError, reason: :eaccess
      end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "ls -l"})
      assert {:error, "Permission denied: ls"} = result
    end

    test "handles other ErlangError reasons" do
      :meck.expect(Store, :get_project, fn -> {:ok, %{source_root: "/test"}} end)
      :meck.expect(System, :cmd, fn _, _, _ -> 
        raise ErlangError, reason: :emfile
      end)

      result = Shell.call(%{"description" => @valid_desc, "cmd" => "some_cmd"})
      assert {:error, "Posix error: emfile"} = result
    end
  end

  describe "spec/0" do
    test "returns valid tool specification" do
      spec = Shell.spec()
      
      assert spec.type == "function"
      assert spec.function.name == "shell_tool"
      assert is_binary(spec.function.description)
      assert spec.function.parameters.required == ["description", "cmd"]
      assert Map.has_key?(spec.function.parameters.properties, :description)
      assert Map.has_key?(spec.function.parameters.properties, :cmd)
    end
  end

  describe "is_available?/0" do
    test "delegates to UI.is_tty?/0" do
      :meck.expect(UI, :is_tty?, fn -> true end)
      assert Shell.is_available?() == true
      
      :meck.expect(UI, :is_tty?, fn -> false end)
      assert Shell.is_available?() == false
    end
  end

  describe "async?/0" do
    test "returns false" do
      assert Shell.async?() == false
    end
  end
end
