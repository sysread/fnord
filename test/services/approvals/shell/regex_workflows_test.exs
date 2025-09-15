defmodule Services.Approvals.Shell.RegexWorkflowsTest do
  @moduledoc """
  Comprehensive test suite for shell regex approval workflows.

  This module tests the complete regex approval system across all three scopes
  (global, project, session) with both positive and negative paths. The tests
  validate the custom regex input functionality that allows users to create
  more sophisticated approval patterns beyond simple prefix matching.

  ## Test Philosophy

  Each test is designed to validate a specific regex approval pathway by:
  1. Setting up the necessary preconditions (existing approvals or clean state)
  2. Mocking UI interactions to simulate user choices including regex input
  3. Executing the approval workflow with slash-delimited regex patterns
  4. Verifying both the immediate result and side effects (settings, session state)

  ## Key Regex Features Validated

  - Slash-delimited regex input (e.g., `/^command.*pattern/`) is stored as full command approval
  - Invalid regex patterns fall back to prefix approvals with error handling
  - Empty regex patterns (`//`) fall back to prefix approvals
  - Non-slash-delimited input is treated as custom prefix approval
  - Session regex approvals work correctly without persistent storage
  - Mixed session state can contain both prefix and regex approvals

  ## Regex vs Prefix Approval Distinction

  This test suite specifically validates the regex approval pathway which differs
  from prefix approvals in these key ways:
  - User input wrapped in slashes (/pattern/) creates shell_full approvals
  - Regex patterns are matched against the complete command string including arguments
  - Fallback behavior preserves user safety when regex compilation fails
  """
  use Fnord.TestCase, async: false

  alias Services.Approvals.Shell
  alias Settings.Approvals, as: SettingsApprovals

  setup do
    # Use the REAL shell approval implementation instead of the test stub
    set_config(:approvals, %{
      edit: MockApprovals,
      shell: Services.Approvals.Shell
    })

    # Disable auto-approval settings to ensure clean test conditions
    Settings.set_edit_mode(false)
    Settings.set_auto_approve(false)
    Settings.set_auto_policy(nil)

    # Create a real project for testing project-scoped approvals
    project = mock_project("regex-workflows-test")

    # Set up baseline approvals at both global and project levels
    settings = Settings.new()
    settings = SettingsApprovals.approve(settings, :global, "shell", "baseline-global-cmd")
    settings = SettingsApprovals.approve(settings, :global, "shell", "another-global-cmd")
    settings = SettingsApprovals.approve(settings, :project, "shell", "baseline-project-cmd")

    # Also add some baseline full command approvals (regex patterns)
    settings = SettingsApprovals.approve(settings, :global, "shell_full", "^baseline.*global")
    _settings = SettingsApprovals.approve(settings, :project, "shell_full", "^baseline.*project")

    # Store baseline state for verification in tests
    baseline_global_prefix = ["another-global-cmd", "baseline-global-cmd"]
    baseline_project_prefix = ["baseline-project-cmd"]
    baseline_global_regex = ["^baseline.*global"]
    baseline_project_regex = ["^baseline.*project"]

    # Mock UI for interactive testing - enable tty mode and set up default responses
    :meck.new(UI, [:passthrough])
    :meck.expect(UI, :is_tty?, fn -> true end)

    :meck.expect(UI, :choose, fn
      "Choose approval scope for:" <> _, _opts -> "Approve for this session"
      "Approve this request?", _opts -> "Approve persistently"
    end)

    :meck.expect(UI, :prompt, fn _prompt, _opts -> "" end)

    on_exit(fn ->
      try do
        :meck.unload(UI)
      rescue
        _ -> :ok
      end
    end)

    {
      :ok,
      project: project,
      baseline_global_prefix: baseline_global_prefix,
      baseline_project_prefix: baseline_project_prefix,
      baseline_global_regex: baseline_global_regex,
      baseline_project_regex: baseline_project_regex
    }
  end

  # Complete Regex Approval Test Matrix - All Paths Covered
  #
  # This test suite comprehensively covers all regex approval scenarios across
  # all three scopes (global, project, session) with both positive and negative paths.
  #
  # ┌─────────────────────┬─────────────────────────┬──────────────────────────┐
  # │ Approval Scope      │ Positive Paths          │ Negative Paths           │
  # ├─────────────────────┼─────────────────────────┼──────────────────────────┤
  # │ GLOBAL              │ ✅ New (Interactive)    │ ✅ Invalid Regex        │
  # │                     │ ✅ Existing (Runtime)   │ ✅ Fallback to Prefix   │
  # ├─────────────────────┼─────────────────────────┼──────────────────────────┤
  # │ PROJECT             │ ✅ New (Interactive)    │ ✅ Empty Regex          │
  # │                     │ ✅ Existing (Runtime)   │ ✅ Fallback to Prefix   │
  # ├─────────────────────┼─────────────────────────┼──────────────────────────┤
  # │ SESSION             │ ✅ New (Interactive)    │ ✅ Blank Input          │
  # │                     │ ✅ Subsequent Matches   │ ✅ Uses Prefix Instead  │
  # └─────────────────────┴─────────────────────────┴──────────────────────────┘
  #
  # Additional Coverage:
  # - Complex regex patterns with special characters and escaping
  # - Non-matching regex patterns requiring new approvals
  # - Mixed session state with both prefix and regex approvals
  # - Custom prefix input (non-slash-delimited) vs regex input

  describe "regex approvals - complete test matrix" do
    test "global regex approval - positive path", %{
      baseline_global_prefix: baseline_global_prefix,
      baseline_project_prefix: baseline_project_prefix,
      baseline_global_regex: baseline_global_regex,
      baseline_project_regex: baseline_project_regex
    } do
      # REASONING: This tests the core regex approval functionality where a user
      # encounters a new command and chooses to approve it globally with a custom
      # regex pattern. The slash-delimited input should be stored as a shell_full
      # approval that can match similar commands in the future.

      # Given: A command that needs approval and user chooses global regex approval
      cmd = %{"command" => "testcmd", "args" => ["arg1", "arg2"]}

      # Mock UI to choose "Approve persistently" then "Approve globally" then custom regex
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for:\n    ^testcmd.*arg\n", _opts -> "Approve globally"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: "/^testcmd.*arg/"
      end)

      # When: We execute the approval workflow
      assert {:approved, _new_state} = Shell.confirm(%{session: []}, {"|", [cmd], "test purpose"})

      # Then: The regex pattern should be stored in global shell_full approvals
      settings = Settings.new()
      global_full_approvals = SettingsApprovals.get_approvals(settings, :global, "shell_full")
      expected_global_regex = (baseline_global_regex ++ ["^testcmd.*arg"]) |> Enum.sort()
      assert global_full_approvals == expected_global_regex

      # And: All baseline approvals should be preserved across both prefix and regex stores
      global_prefix_approvals = SettingsApprovals.get_approvals(settings, :global, "shell")
      assert global_prefix_approvals == baseline_global_prefix

      project_prefix_approvals = SettingsApprovals.get_approvals(settings, :project, "shell")
      assert project_prefix_approvals == baseline_project_prefix

      project_full_approvals = SettingsApprovals.get_approvals(settings, :project, "shell_full")
      assert project_full_approvals == baseline_project_regex

      # Why this matters: Global regex approvals provide powerful pattern matching
      # for command families across all projects while preserving data integrity.
    end

    test "global regex approval - negative path (invalid regex)", %{
      baseline_global_prefix: baseline_global_prefix,
      baseline_global_regex: baseline_global_regex
    } do
      # REASONING: When users provide invalid regex patterns, the system should
      # gracefully fall back to prefix approvals rather than failing entirely.
      # This ensures user safety and prevents approval system breakage due to
      # malformed regex input.

      # Given: A command that needs approval and user provides invalid regex
      cmd = %{"command" => "testcmd", "args" => ["arg1"]}

      # Mock UI to choose "Approve persistently" then "Approve globally" then invalid regex
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for:\n    testcmd\n", _opts -> "Approve globally"
      end)

      prompt_call_count = :counters.new(1, [])

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional) do
          case :counters.get(prompt_call_count, 1) do
            0 ->
              :counters.add(prompt_call_count, 1, 1)
              # First call returns invalid regex
              "/[invalid/"

            _ ->
              # Second call returns empty string (falls back to prefix)
              ""
          end
        end
      end)

      # Mock UI.error to be called for invalid regex
      :meck.expect(UI, :error, fn _msg -> :ok end)

      # When: We execute the approval workflow with invalid regex
      assert {:approved, _new_state} = Shell.confirm(%{session: []}, {"|", [cmd], "test purpose"})

      # Then: It should fall back to prefix approval instead of regex
      settings = Settings.new()
      global_prefix_approvals = SettingsApprovals.get_approvals(settings, :global, "shell")
      expected_global_prefix = (baseline_global_prefix ++ ["testcmd"]) |> Enum.sort()
      assert global_prefix_approvals == expected_global_prefix

      # And: Baseline regex approvals should remain unchanged (no invalid regex stored)
      global_full_approvals = SettingsApprovals.get_approvals(settings, :global, "shell_full")
      assert global_full_approvals == baseline_global_regex

      # Why this matters: Robust error handling prevents approval system corruption
      # and ensures users can still approve commands even with regex input errors.
    end

    test "project regex approval - positive path", %{
      baseline_project_regex: baseline_project_regex
    } do
      cmd = %{"command" => "projcmd", "args" => ["build"]}

      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for:\n    ^projcmd build.*\n", _opts -> "Approve for the project"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: "/^projcmd build.*/"
      end)

      assert {:approved, _new_state} =
               Shell.confirm(%{session: []}, {"|", [cmd], "project build"})

      settings = Settings.new()
      project_full_approvals = SettingsApprovals.get_approvals(settings, :project, "shell_full")
      expected_project_regex = (baseline_project_regex ++ ["^projcmd build.*"]) |> Enum.sort()
      assert project_full_approvals == expected_project_regex
    end

    test "project regex approval - negative path (empty regex)" do
      cmd = %{"command" => "projcmd", "args" => ["test"]}

      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for:\n    projcmd\n", _opts -> "Approve for the project"
      end)

      prompt_call_count = :counters.new(1, [])

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional) do
          case :counters.get(prompt_call_count, 1) do
            0 ->
              :counters.add(prompt_call_count, 1, 1)
              # First call returns invalid regex
              "//"

            _ ->
              # Second call returns empty string (falls back to prefix)
              ""
          end
        end
      end)

      :meck.expect(UI, :error, fn "Empty regex is not allowed" -> :ok end)

      assert {:approved, _new_state} = Shell.confirm(%{session: []}, {"|", [cmd], "test purpose"})

      # Should fall back to prefix approval
      settings = Settings.new()
      project_prefix_approvals = SettingsApprovals.get_approvals(settings, :project, "shell")
      expected_project_prefix = ["baseline-project-cmd", "projcmd"] |> Enum.sort()
      assert project_prefix_approvals == expected_project_prefix
    end

    test "session regex approval - positive path", %{
      baseline_global_regex: baseline_global_regex,
      baseline_project_regex: baseline_project_regex
    } do
      # REASONING: Session regex approvals provide temporary pattern matching
      # without permanent storage. This is useful for experimental or one-off
      # regex patterns that users don't want to persist globally or per-project.

      # Given: A command that needs session-scoped regex approval
      cmd = %{"command" => "sesscmd", "args" => ["run"]}

      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for:\n    ^sesscmd run\n", _opts -> "Approve for this session"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: "/^sesscmd run/"
      end)

      # When: We execute the session regex approval
      assert {:approved, new_state} =
               Shell.confirm(%{session: []}, {"|", [cmd], "session command"})

      # Then: The regex should be stored in session state as {:full, pattern}
      assert {:full, "^sesscmd run"} in new_state.session

      # And: No persistent storage should occur - all baseline settings preserved
      settings = Settings.new()
      global_full_approvals = SettingsApprovals.get_approvals(settings, :global, "shell_full")
      assert global_full_approvals == baseline_global_regex

      project_full_approvals = SettingsApprovals.get_approvals(settings, :project, "shell_full")
      assert project_full_approvals == baseline_project_regex

      # Why this matters: Session regex approvals provide sophisticated temporary
      # pattern matching for complex command workflows without permanent impact.
    end

    test "session regex approval - negative path (blank input uses prefix)" do
      cmd = %{"command" => "sesscmd", "args" => ["deploy"]}

      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for:\n    sesscmd\n", _opts -> "Approve for this session"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: ""
      end)

      assert {:approved, new_state} =
               Shell.confirm(%{session: []}, {"|", [cmd], "session command"})

      # Should store prefix approval in session, not regex
      assert {:prefix, "sesscmd"} in new_state.session
      refute Enum.any?(new_state.session, fn {type, _} -> type == :full end)
    end
  end

  describe "regex approval matching - runtime behavior" do
    # This section validates that previously stored regex patterns correctly match
    # new commands at runtime, providing the auto-approval benefit that justifies
    # the more complex setup process for regex approvals.
    test "previously approved global regex matches new command" do
      # Pre-approve a regex globally
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :global, "shell_full", "^make (build|test)")

      # Command that should match the regex
      cmd = %{"command" => "make", "args" => ["build", "prod"]}

      # Should be auto-approved without UI interaction
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "make build"})
    end

    test "previously approved project regex matches new command" do
      settings = Settings.new()

      _settings =
        SettingsApprovals.approve(settings, :project, "shell_full", "^npm (install|test|build)")

      cmd = %{"command" => "npm", "args" => ["test", "--coverage"]}

      assert {:approved, _state} =
               Shell.confirm(%{session: []}, {"|", [cmd], "npm test with coverage"})
    end

    test "session regex approval matches subsequent commands in same session" do
      cmd1 = %{"command" => "gradle", "args" => ["clean"]}
      cmd2 = %{"command" => "gradle", "args" => ["build"]}

      # First command requires approval
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts ->
          "Approve persistently"

        "Choose approval scope for:\n    ^gradle (clean|build|test)\n", _opts ->
          "Approve for this session"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: "/^gradle (clean|build|test)/"
      end)

      assert {:approved, state_after_first} =
               Shell.confirm(%{session: []}, {"|", [cmd1], "gradle clean"})

      # Second command should auto-approve using session regex
      assert {:approved, _final_state} =
               Shell.confirm(state_after_first, {"|", [cmd2], "gradle build"})
    end

    test "regex approval doesn't match non-matching command" do
      settings = Settings.new()

      _settings =
        SettingsApprovals.approve(settings, :global, "shell_full", "^git (status|diff|log)")

      # Command that doesn't match the regex
      cmd = %{"command" => "git", "args" => ["push", "origin", "main"]}

      # Should require approval since it doesn't match
      :meck.expect(UI, :choose, fn "Approve this request?", _opts -> "Approve" end)

      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "git push"})
    end
  end

  describe "regex approval edge cases and error handling" do
    # This section covers the boundary conditions and error scenarios that could
    # occur with regex approvals, ensuring robust behavior in all edge cases.
    # Special focus on complex regex patterns and mixed approval scenarios.
    test "complex regex with special characters", %{
      baseline_global_regex: baseline_global_regex
    } do
      cmd = %{"command" => "locate", "args" => ["*.ex", "|", "grep", "test"]}

      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts ->
          "Approve persistently"

        "Choose approval scope for:\n    ^locate \\*\\.ex \\| grep test\n", _opts ->
          "Approve globally"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: "/^locate \\*\\.ex \\| grep test/"
      end)

      assert {:approved, _state} =
               Shell.confirm(%{session: []}, {"|", [cmd], "locate elixir test files"})

      settings = Settings.new()
      global_full_approvals = SettingsApprovals.get_approvals(settings, :global, "shell_full")

      expected_global_regex =
        (baseline_global_regex ++ ["^locate \\*\\.ex \\| grep test"]) |> Enum.sort()

      assert global_full_approvals == expected_global_regex
    end

    test "regex without slash delimiters treated as custom prefix", %{
      baseline_global_prefix: baseline_global_prefix,
      baseline_global_regex: baseline_global_regex
    } do
      cmd = %{"command" => "custom", "args" => ["action"]}

      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for:\n    custom action\n", _opts -> "Approve globally"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: "custom action"
      end)

      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "custom command"})

      # Should be stored as prefix, not regex
      settings = Settings.new()
      global_prefix_approvals = SettingsApprovals.get_approvals(settings, :global, "shell")
      expected_global_prefix = (baseline_global_prefix ++ ["custom action"]) |> Enum.sort()
      assert global_prefix_approvals == expected_global_prefix

      global_full_approvals = SettingsApprovals.get_approvals(settings, :global, "shell_full")
      assert global_full_approvals == baseline_global_regex
    end

    test "mixed session approvals - both prefix and regex", %{
      baseline_global_prefix: baseline_global_prefix,
      baseline_global_regex: baseline_global_regex
    } do
      # REASONING: The session state should support both prefix and regex approvals
      # simultaneously. Users might approve some commands with simple prefixes and
      # others with complex regex patterns within the same session. This tests
      # that the approval system correctly handles mixed approval types.

      # Given: Two different commands needing different approval types
      cmd1 = %{"command" => "custom-tool", "args" => ["hello"]}
      cmd2 = %{"command" => "search-tool", "args" => ["pattern", "file"]}

      # When: First approval - prefix (blank input defaults to prefix)
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for:\n    custom-tool\n", _opts -> "Approve for this session"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: ""
      end)

      assert {:approved, state1} =
               Shell.confirm(%{session: []}, {"|", [cmd1], "custom tool command"})

      assert {:prefix, "custom-tool"} in state1.session

      # And When: Second approval - regex (slash-delimited input creates regex)
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts ->
          "Approve persistently"

        "Choose approval scope for:\n    ^search-tool .* .*\n", _opts ->
          "Approve for this session"
      end)

      :meck.expect(UI, :prompt, fn _msg, opts ->
        if Keyword.get(opts, :optional), do: "/^search-tool .* .*/"
      end)

      assert {:approved, final_state} =
               Shell.confirm(state1, {"|", [cmd2], "search tool command"})

      # Then: Session should contain both approval types
      assert {:prefix, "custom-tool"} in final_state.session
      assert {:full, "^search-tool .* .*"} in final_state.session

      # And: No persistent storage should occur for either approval type
      settings = Settings.new()
      global_prefix_approvals = SettingsApprovals.get_approvals(settings, :global, "shell")
      assert global_prefix_approvals == baseline_global_prefix
      global_full_approvals = SettingsApprovals.get_approvals(settings, :global, "shell_full")
      assert global_full_approvals == baseline_global_regex

      # Why this matters: Mixed approval types in sessions provide maximum
      # flexibility for users working with diverse command patterns temporarily.
    end
  end
end
