defmodule Services.ApprovalsTest do
  use Fnord.TestCase, async: false

  alias Services.Approvals

  @approval_tag "tag"
  @approval_subject "subject"
  @message "Please approve action"
  @detail "Detail message"
  @opts [tag: @approval_tag, subject: @approval_subject, message: @message, detail: @detail]

  test "bypasses prompt when session-approved" do
    :meck.new(UI, [:passthrough])

    :meck.expect(UI, :choose, fn _, _ ->
      flunk("UI.choose should not be called when already session-approved")
    end)

    assert {:ok, :approved} = Approvals.approve(:session, @approval_tag, @approval_subject)

    _ =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, :approved} = Approvals.confirm(@opts)
      end)

    :meck.unload(UI)
  end

  test "bypasses prompt when project-approved" do
    project = "test_project"
    set_config(:project, project)
    :meck.new(UI, [:passthrough])

    :meck.expect(UI, :choose, fn _, _ ->
      flunk("UI.choose should not be called when already project-approved")
    end)

    assert {:ok, :approved} = Approvals.approve(:project, @approval_tag, @approval_subject)

    _ =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, :approved} = Approvals.confirm(@opts)
      end)

    :meck.unload(UI)
  end

  test "prompts and auto-denies when not approved" do
    # Stub UI.choose to simulate non-interactive session
    :meck.new(UI, [:passthrough])
    :meck.expect(UI, :choose, fn _, _ -> {:error, :no_tty} end)

    captured_output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, msg} = Approvals.confirm(@opts)
        # The error message should still indicate denial and include the subject
        assert msg =~ "> #{@approval_subject}"
        assert msg =~ "automatically denied"
      end)

    # Verify that the permission dialog was rendered before auto-deny
    assert captured_output =~ "PERMISSION REQUEST"
    assert captured_output =~ @detail

    :meck.unload(UI)
  end

  test "auto-deny when UI.choose returns no_tty explicitly" do
    :meck.new(UI, [:passthrough])

    :meck.expect(UI, :choose, fn _, _ ->
      {:error, :no_tty}
    end)

    captured_output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, msg} = Approvals.confirm(@opts)
        # The error message should still indicate denial and include the subject
        assert msg =~ "> #{@approval_subject}"
        assert msg =~ "automatically denied"
      end)

    # Verify that the permission dialog was rendered before auto-deny
    assert captured_output =~ "PERMISSION REQUEST"
    assert captured_output =~ @detail

    :meck.unload(UI)
  end

  describe "pattern matching" do
    test "exact string match works (backward compatibility)" do
      # Approve exact subject
      assert {:ok, :approved} = Approvals.approve(:session, "shell_cmd", "git log")

      # Should match exact subject
      assert Approvals.is_approved?("shell_cmd", "git log")

      # Should not match different subject
      refute Approvals.is_approved?("shell_cmd", "git status")
    end

    test "regex pattern matching works" do
      # Approve with regex pattern (must have both delimiters)
      assert {:ok, :approved} = Approvals.approve(:session, "shell_cmd", "m/git .*/")

      # Should match git commands
      assert Approvals.is_approved?("shell_cmd", "git log")
      assert Approvals.is_approved?("shell_cmd", "git status")
      assert Approvals.is_approved?("shell_cmd", "git diff --cached")

      # Should not match non-git commands
      refute Approvals.is_approved?("shell_cmd", "ls -la")
      refute Approvals.is_approved?("shell_cmd", "npm install")
    end

    test "complex regex patterns work" do
      # Approve npm commands except publish (must have both delimiters)
      assert {:ok, :approved} = Approvals.approve(:session, "shell_cmd", "m/npm (?!publish).*/")

      # Should match npm commands except publish
      assert Approvals.is_approved?("shell_cmd", "npm install")
      assert Approvals.is_approved?("shell_cmd", "npm update")
      assert Approvals.is_approved?("shell_cmd", "npm audit")

      # Should not match npm publish
      refute Approvals.is_approved?("shell_cmd", "npm publish")

      # Should not match non-npm commands
      refute Approvals.is_approved?("shell_cmd", "git log")
    end

    test "invalid regex patterns are ignored" do
      # Try to approve with invalid regex (has proper delimiters but bad pattern)
      assert {:ok, :approved} = Approvals.approve(:session, "shell_cmd", "m/[invalid/")

      # Should not match anything due to invalid regex
      refute Approvals.is_approved?("shell_cmd", "git log")
      refute Approvals.is_approved?("shell_cmd", "[invalid")
    end

    test "absolute paths work without m/ prefix" do
      # Approve absolute path
      assert {:ok, :approved} =
               Approvals.approve(:session, "shell_cmd", "/usr/local/bin/mycommand")

      # Should match exact path
      assert Approvals.is_approved?("shell_cmd", "/usr/local/bin/mycommand")

      # Should not match different path
      refute Approvals.is_approved?("shell_cmd", "/usr/bin/mycommand")
    end

    test "project-level pattern matching works" do
      project = "test_project"
      set_config(:project, project)

      # Approve with pattern at project level (must have both delimiters)
      assert {:ok, :approved} = Approvals.approve(:project, "shell_cmd", "m/find .*/")

      # Should match find commands
      assert Approvals.is_approved?("shell_cmd", "find . -name '*.ex'")
      assert Approvals.is_approved?("shell_cmd", "find /tmp -type f")

      # Should not match non-find commands
      refute Approvals.is_approved?("shell_cmd", "ls -la")
    end

    test "regex patterns require both delimiters" do
      # Pattern with proper delimiters works as regex
      assert {:ok, :approved} = Approvals.approve(:session, "shell_cmd", "m/docker (build|ps)/")

      # Should match docker commands
      assert Approvals.is_approved?("shell_cmd", "docker build")
      assert Approvals.is_approved?("shell_cmd", "docker ps")
      refute Approvals.is_approved?("shell_cmd", "docker run")

      # Pattern without trailing delimiter is treated as exact string
      assert {:ok, :approved} = Approvals.approve(:session, "shell_cmd", "m/git log")

      # Should only match the exact string, not as a regex
      assert Approvals.is_approved?("shell_cmd", "m/git log")
      refute Approvals.is_approved?("shell_cmd", "git log")
      refute Approvals.is_approved?("shell_cmd", "git status")
    end

    test "global regex patterns work after service restart" do
      # First approve a regex pattern globally (must have both delimiters)
      assert {:ok, :approved} = Approvals.approve(:global, "shell_cmd", "m/git .*/")

      # Verify it works initially
      assert Approvals.is_approved?("shell_cmd", "git log")
      assert Approvals.is_approved?("shell_cmd", "git status")
      refute Approvals.is_approved?("shell_cmd", "npm install")

      # Restart the approvals service to test loading from settings
      GenServer.stop(Services.Approvals, :normal)
      {:ok, _pid} = Services.Approvals.start_link()

      # Verify the regex pattern still works after restart
      assert Approvals.is_approved?("shell_cmd", "git log")
      assert Approvals.is_approved?("shell_cmd", "git status")
      refute Approvals.is_approved?("shell_cmd", "npm install")
    end

    test "exact matching with anchored regex patterns" do
      # File operations require exact subject matching to prevent overly broad approvals
      assert {:ok, :approved} = Approvals.approve(:session, "general", "m/^edit files$/")

      # Should match exact string
      assert Approvals.is_approved?("general", "edit files")

      # Should NOT match with additional text
      refute Approvals.is_approved?("general", "edit files with more")
      refute Approvals.is_approved?("general", "prefix edit files")
    end

    test "all pattern examples from help text work with Elixir regex" do
      # Get the pattern examples used in help text
      pattern_examples = [
        ["git log", "Exact match (matches only git log)"],
        ["m/git .*/", "Regex (matches all git commands)"],
        ["m/docker (build|ps)/", "Regex with alternation (docker build or ps)"],
        ["m/npm (?!publish).*/", "Complex (npm except publish)"],
        ["m/find\\s+(?!.*-exec\\b).*/", "Safe find (find without -exec)"],
        ["/usr/local/bin/foo", "Paths (absolute paths)"]
      ]

      for [pattern, description] <- pattern_examples do
        if String.starts_with?(pattern, "m/") and String.ends_with?(pattern, "/") do
          # Extract and test regex compilation (same logic as matches_pattern?)
          regex_pattern = String.slice(pattern, 2..-2//1)

          case Regex.compile(regex_pattern) do
            {:ok, regex} ->
              # Test specific cases for each pattern
              case description do
                "Regex (matches all git commands)" ->
                  assert Regex.match?(regex, "git log")
                  assert Regex.match?(regex, "git status")
                  assert Regex.match?(regex, "git diff --cached")
                  refute Regex.match?(regex, "ls -la")

                "Regex with alternation (docker build or ps)" ->
                  assert Regex.match?(regex, "docker build")
                  assert Regex.match?(regex, "docker ps")
                  refute Regex.match?(regex, "docker run")

                "Complex (npm except publish)" ->
                  assert Regex.match?(regex, "npm install")
                  assert Regex.match?(regex, "npm update")
                  assert Regex.match?(regex, "npm audit")
                  refute Regex.match?(regex, "npm publish")

                "Safe find (find without -exec)" ->
                  assert Regex.match?(regex, "find . -name '*.ex'")
                  assert Regex.match?(regex, "find /tmp -type f")
                  refute Regex.match?(regex, "find . -exec rm {} \\;")

                _ ->
                  # At minimum, verify the regex compiles without error
                  :ok
              end

            {:error, reason} ->
              flunk(
                "Pattern example '#{pattern}' (#{description}) failed to compile: #{inspect(reason)}"
              )
          end
        else
          # Non-regex patterns should work as exact matches
          case description do
            "Exact match (matches only git log)" ->
              assert pattern == "git log"

            "Paths (absolute paths)" ->
              assert String.starts_with?(pattern, "/")

            _ ->
              # At minimum, verify it's a valid string
              assert is_binary(pattern)
          end
        end
      end
    end
  end
end
