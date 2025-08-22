defmodule AI.Tools.Shell.PreapprovedTest do
  use Fnord.TestCase, async: false
  alias AI.Tools.Shell

  setup do
    # Ensure any existing meck processes are unloaded before starting new mocks
    try do
      :meck.unload(Services.Approvals)
    rescue
      _ -> :ok
    end

    # Create fresh mocks for each test
    try do
      :meck.new(Services.Approvals, [:passthrough])
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      try do
        :meck.unload(Services.Approvals)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "ls skips approval and runs" do
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      flunk("confirm should NOT be called")
    end)

    assert {:ok, result} =
             Shell.call(%{"description" => "list", "command" => "ls -la"})

    assert result =~ "Command: `ls -la`"
  end

  test "git log skips approval" do
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      flunk("confirm should NOT be called")
    end)

    assert {:ok, result} =
             Shell.call(%{"description" => "git log", "command" => "git log"})

    assert result =~ "Command: `git log`"
  end

  test "git log with extra args skips approval" do
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      flunk("confirm should NOT be called for git log with extra args")
    end)

    # Should be preapproved since git log allows additional arguments
    assert {:ok, result} =
             Shell.call(%{
               "description" => "git log with args",
               "command" => "git log --oneline -10"
             })

    assert result =~ "Command: `git log --oneline -10`"
  end

  test "git remote still asks approval" do
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      {:ok, :approved}
    end)

    assert {:ok, _} =
             Shell.call(%{"description" => "remote", "command" => "git remote"})
  end

  test "malicious commands that start with allowed command names are blocked" do
    # Security test: commands like 'catastrophe' should NOT be auto-approved
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      {:ok, :approved}
    end)

    # This should require approval (not be preapproved) and then execute but show command doesn't exist
    assert {:ok, output} =
             Shell.call(%{
               "description" => "malicious",
               "command" => "catastrophe"
             })

    # Should show command not found in output and non-zero exit code
    assert output =~ "command not found" and output =~ "Exit Status: `127`"
  end

  test "allowed command patterns work correctly" do
    # Direct test of the Allowed module
    alias AI.Tools.Shell.Allowed

    # These should be allowed
    assert Allowed.allowed?("cat", ["cat", "file.txt"])
    assert Allowed.allowed?("ls", ["ls"])
    assert Allowed.allowed?("git", ["git", "status"])
    assert Allowed.allowed?("git", ["git", "merge-base", "main", "feature"])
    assert Allowed.allowed?("pwd", ["pwd"])

    # These should NOT be allowed (security test)
    refute Allowed.allowed?("catastrophe", ["catastrophe"])
    refute Allowed.allowed?("lsblk", ["lsblk"])
    refute Allowed.allowed?("headache", ["headache"])
    refute Allowed.allowed?("git", ["git", "push"])
  end

  test "plain strings work as prefixes with additional arguments" do
    alias AI.Tools.Shell.Allowed

    # Test that preapproved commands allow additional arguments 
    assert Allowed.allowed?("git", ["git", "log"])
    assert Allowed.allowed?("git", ["git", "log", "--oneline"])
    assert Allowed.allowed?("git", ["git", "log", "--oneline", "-10"])

    # But "git push" should not match "git log" pattern
    refute Allowed.allowed?("git", ["git", "push"])
    refute Allowed.allowed?("git", ["git", "remote"])

    # Test with single commands + args
    assert Allowed.allowed?("cat", ["cat"])
    assert Allowed.allowed?("cat", ["cat", "file.txt"])
    assert Allowed.allowed?("ls", ["ls", "-la", "/tmp"])

    # But partial matches should not work
    refute Allowed.allowed?("catastrophe", ["catastrophe"])
    refute Allowed.allowed?("lsblk", ["lsblk"])
  end

  test "dynamic anchoring prevents partial matches" do
    alias AI.Tools.Shell.Allowed

    # Commands with similar names should not match preapproved patterns
    refute Allowed.allowed?("pwdx", ["pwdx"])

    # But "pwd" should match
    assert Allowed.allowed?("pwd", ["pwd"])

    # Test with commands that have arguments
    assert Allowed.allowed?("cat", ["cat", "/etc/passwd"])
    refute Allowed.allowed?("concatenate", ["concatenate", "files"])
  end

  test "complex commands require manual approval" do
    # Mock to expect manual approval for complex commands
    :meck.expect(Services.Approvals, :confirm, fn opts ->
      # Verify it's asking for approval with the right parameters
      assert Keyword.get(opts, :tag) == "shell_cmd"
      # Complex commands can't be pre-approved
      assert Keyword.get(opts, :persistent) == false
      {:ok, :approved}
    end)

    # Test complex command with pipe
    assert {:ok, result} =
             Shell.call(%{
               "description" => "list and filter",
               "command" => "ls -la | grep test"
             })

    assert result =~ "Command: `ls -la | grep test`"

    {:ok, tmp} = Briefly.create()

    # Test complex command with redirect  
    assert {:ok, result} =
             Shell.call(%{
               "description" => "save output",
               "command" => "ls > #{tmp}/files.txt"
             })

    assert result =~ "Command: `ls > #{tmp}/files.txt`"

    # Test complex command with command chaining
    assert {:ok, result} =
             Shell.call(%{
               "description" => "multiple commands",
               "command" => "pwd && ls"
             })

    assert result =~ "Command: `pwd && ls`"
  end
end
