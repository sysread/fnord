defmodule Services.Approvals.Shell.SedSecurityPatternsTest do
  @moduledoc """
  Tests hard-coded security patterns for sed commands to prevent regression
  in approval/denial decisions for known-safe and known-dangerous patterns.

  This test serves as documentation of security decisions and regression prevention.
  """

  use Fnord.TestCase, async: false

  alias Services.Approvals.Shell

  setup do
    # Ensure no persisted approvals affect tests
    File.rm_rf!(Settings.settings_file())

    # Allow UI calls to pass through but simulate non-interactive mode
    :meck.new(UI, [:passthrough])
    :meck.expect(UI, :is_tty?, fn -> false end)

    on_exit(fn ->
      try do
        :meck.unload(UI)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "safe sed patterns (should approve)" do
    test "read-only operations" do
      # Line range printing
      cmd1 = %{"command" => "sed", "args" => ["-n", "10,20p", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd1], "print lines"})

      # Pattern matching and printing
      cmd2 = %{"command" => "sed", "args" => ["-n", "/pattern/p", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd2], "print matches"})

      # Line deletion (read-only output)
      cmd3 = %{"command" => "sed", "args" => ["1d", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd3], "delete first line"})
    end

    test "safe substitution patterns" do
      # Basic substitution (no execute flag)
      cmd1 = %{"command" => "sed", "args" => ["s/foo/bar/g", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd1], "substitute foo->bar"})

      # Extended regex substitution
      cmd2 = %{"command" => "sed", "args" => ["-E", "s/foo|bar/baz/g", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd2], "extended regex"})

      # Pipe delimiters (safe without execute)
      cmd3 = %{"command" => "sed", "args" => ["s|foo|bar|g", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd3], "pipe delimiters"})
    end
  end

  describe "dangerous sed patterns (should deny)" do
    test "file modification operations" do
      # In-place editing
      cmd1 = %{"command" => "sed", "args" => ["-i", "", "s/foo/bar/", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [cmd1], "in-place edit"})

      # In-place with backup
      cmd2 = %{"command" => "sed", "args" => ["-i", ".bak", "s/foo/bar/", "file.txt"]}

      assert {:denied, _, _} =
               Shell.confirm(%{session: []}, {"|", [cmd2], "in-place with backup"})
    end

    test "file I/O operations" do
      # Write to file
      cmd1 = %{"command" => "sed", "args" => ["1w output.txt", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [cmd1], "write to file"})

      # Write command with range
      cmd2 = %{"command" => "sed", "args" => ["-n", "1,10w out.txt", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [cmd2], "range write"})

      # Capital W command
      cmd3 = %{"command" => "sed", "args" => ["W backup.txt", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [cmd3], "write first line"})

      # Read file command
      cmd4 = %{"command" => "sed", "args" => ["1r header.txt", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [cmd4], "read file"})
    end

    test "code execution operations" do
      # Execute flag in substitution (forward slashes)
      cmd1 = %{"command" => "sed", "args" => ["s/foo/bar/e", "file.txt"]}

      assert {:denied, _, _} =
               Shell.confirm(%{session: []}, {"|", [cmd1], "execute substitution"})

      # Execute flag with pipe delimiters
      cmd2 = %{"command" => "sed", "args" => ["s|foo|bar|e", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [cmd2], "execute with pipes"})

      # Expression flag
      cmd3 = %{"command" => "sed", "args" => ["-e", "s/foo/bar/", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [cmd3], "expression flag"})

      # Script file execution
      cmd4 = %{"command" => "sed", "args" => ["-f", "script.sed", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [cmd4], "script file"})
    end
  end
end
