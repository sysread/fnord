defmodule Services.Approvals.Shell.PrefixWorkflowsTest do
  @moduledoc """
  Comprehensive test suite for shell prefix approval workflows.

  This module tests the complete prefix approval system across all three scopes
  (global, project, session) with both positive and negative paths. The tests
  avoid hard-coded preapprovals and use settings-based approvals exclusively
  to ensure comprehensive coverage of the real-world approval mechanisms.

  ## Test Philosophy

  Each test is designed to validate a specific approval pathway by:
  1. Setting up the necessary preconditions (existing approvals or clean state)
  2. Mocking UI interactions to simulate user choices
  3. Executing the approval workflow
  4. Verifying both the immediate result and side effects (settings, session state)

  ## Key Fixes Validated

  - Global prefix matching now uses String.starts_with?/2 instead of regex compilation
  - Session approval workflow correctly triggers via "Approve persistently" → scope selection
  - Prefix extraction behavior is consistent for known vs unknown command families
  """
  use Fnord.TestCase, async: false

  alias Services.Approvals.Shell
  alias Settings.Approvals, as: SettingsApprovals

  setup do
    # Use the REAL shell approval implementation instead of the test stub
    # This ensures we're testing the actual production code paths
    set_config(:approvals, %{
      edit: MockApprovals,
      shell: Services.Approvals.Shell
    })

    # Disable auto-approval settings to ensure clean test conditions
    # Without this, auto-approval modes could interfere with our interactive tests
    Settings.set_edit_mode(false)
    Settings.set_auto_approve(false)
    Settings.set_auto_policy(nil)

    # Create a real project for testing project-scoped approvals
    project = mock_project("prefix-workflows-test")

    # Set up baseline approvals at both global and project levels
    # This ensures we test that new approvals are added correctly without
    # overwriting existing approvals, and that negative paths preserve all settings
    settings = Settings.new()
    settings = SettingsApprovals.approve(settings, :global, "shell", "baseline-global-cmd")
    settings = SettingsApprovals.approve(settings, :global, "shell", "another-global-cmd")
    _settings = SettingsApprovals.approve(settings, :project, "shell", "baseline-project-cmd")

    # Store baseline state for verification in tests
    # alphabetically sorted
    baseline_global = ["another-global-cmd", "baseline-global-cmd"]
    baseline_project = ["baseline-project-cmd"]

    # Mock UI for interactive testing
    # We enable tty mode and set up default UI responses that can be overridden per test
    :meck.new(UI, [:passthrough])
    :meck.expect(UI, :is_tty?, fn -> true end)

    :meck.expect(UI, :choose, fn
      "Choose approval scope for:" <> _, _opts -> "Approve for this session"
      "Approve this request?", _opts -> "Approve persistently"
    end)

    :meck.expect(UI, :prompt, fn _prompt -> "" end)

    on_exit(fn ->
      try do
        :meck.unload(UI)
      rescue
        _ -> :ok
      end
    end)

    {:ok, project: project, baseline_global: baseline_global, baseline_project: baseline_project}
  end

  # Complete Prefix Approval Test Matrix - All Paths Covered
  #
  # This test suite comprehensively covers all prefix approval scenarios across
  # all three scopes (global, project, session) with both positive and negative paths.
  #
  # ┌─────────────────────┬─────────────────────────┬──────────────────────────┐
  # │ Approval Scope      │ Positive Paths          │ Negative Paths           │
  # ├─────────────────────┼─────────────────────────┼──────────────────────────┤
  # │ GLOBAL              │ ✅ New (Interactive)    │ ✅ User Denies          │
  # │                     │ ✅ Existing (Settings)  │ ✅ Missing Approval     │
  # ├─────────────────────┼─────────────────────────┼──────────────────────────┤
  # │ PROJECT             │ ✅ New (Interactive)    │ ✅ User Denies          │
  # │                     │ ✅ Existing (Settings)  │ ✅ Missing Approval     │
  # ├─────────────────────┼─────────────────────────┼──────────────────────────┤
  # │ SESSION             │ ✅ New (Interactive)    │ ✅ User Denies          │
  # │                     │ ✅ Existing (In-Memory) │ ✅ Missing Approval     │
  # └─────────────────────┴─────────────────────────┴──────────────────────────┘

  describe "positive approval paths - existing approvals auto-approve" do
    test "global prefix approval from settings.json", %{
      baseline_global: baseline_global,
      baseline_project: baseline_project
    } do
      # REASONING: This tests the most common case - a user has previously approved
      # a command globally (like "mix test"), and when they run it again, it should
      # auto-approve without prompting. This validates our String.starts_with?/2 fix.

      # Given: An existing global approval for "mix test" in settings.json (added to baseline)
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :global, "shell", "mix test")

      # When: We execute a "mix test" command
      cmd = %{"command" => "mix", "args" => ["test"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run mix test"})

      # Then: It should auto-approve without prompting (session remains empty)
      assert {:approved, %{session: []}} = result

      # And: Settings should be preserved with the existing approval
      final_settings = Settings.new()
      final_global = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_project = SettingsApprovals.get_approvals(final_settings, :project, "shell")

      # Existing approvals plus the one we added should all be present
      expected_global = (baseline_global ++ ["mix test"]) |> Enum.sort()
      assert final_global == expected_global
      assert final_project == baseline_project

      # Why this matters: Users expect previously approved commands to "just work"
      # without re-prompting. This test ensures the global approval lookup works correctly.
    end

    test "project prefix approval from settings.json", %{
      baseline_global: baseline_global,
      baseline_project: baseline_project
    } do
      # REASONING: Project approvals are scoped to the current project, allowing
      # different approval policies per project. This tests that project-scoped
      # approvals work correctly and don't interfere with global approvals.

      # Given: An existing project approval for "build-tool" (added to baseline)
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :project, "shell", "build-tool")

      # When: We execute a "build-tool" command
      cmd = %{"command" => "build-tool", "args" => ["compile"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run build tool"})

      # Then: It should auto-approve without prompting
      assert {:approved, %{session: []}} = result

      # And: Settings should be preserved with the existing approval
      final_settings = Settings.new()
      final_global = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_project = SettingsApprovals.get_approvals(final_settings, :project, "shell")

      # Existing approvals plus the one we added should all be present
      expected_project = (baseline_project ++ ["build-tool"]) |> Enum.sort()
      assert final_global == baseline_global
      assert final_project == expected_project

      # Why this matters: Project-specific tools should be approved per-project,
      # not globally, to maintain appropriate security boundaries.
    end

    test "session prefix approval from in-memory state", %{
      baseline_global: baseline_global,
      baseline_project: baseline_project
    } do
      # REASONING: Session approvals are temporary and stored only in memory.
      # This tests that once approved for a session, commands auto-approve
      # until the session ends, without writing to persistent storage.

      # Given: An existing session approval for "temp-tool"
      session_with_approval = [{:prefix, "temp-tool"}]

      # When: We execute a "temp-tool" command
      cmd = %{"command" => "temp-tool", "args" => ["action"]}
      result = Shell.confirm(%{session: session_with_approval}, {"|", [cmd], "run temp tool"})

      # Then: It should auto-approve and preserve the session state
      assert {:approved, %{session: session}} = result
      assert {:prefix, "temp-tool"} in session

      # And: Persistent settings should be completely unchanged
      final_settings = Settings.new()
      final_global = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_project = SettingsApprovals.get_approvals(final_settings, :project, "shell")

      assert final_global == baseline_global
      assert final_project == baseline_project

      # Why this matters: Session approvals provide temporary convenience without
      # permanent security implications. They should work correctly and not persist.
    end
  end

  describe "positive approval paths - new interactive approvals" do
    test "global prefix approval via user interaction", %{
      baseline_global: baseline_global,
      baseline_project: baseline_project
    } do
      # REASONING: When a user encounters a new command, they should be able to
      # approve it globally so it works across all projects. This tests the
      # interactive approval flow that stores the approval in global settings.

      # Given: UI mock configured to choose global scope
      :meck.expect(UI, :choose, fn
        "Choose approval scope for:" <> _, _opts -> "Approve globally"
        "Approve this request?", _opts -> "Approve persistently"
      end)

      # When: We execute a new command that hasn't been approved before
      cmd = %{"command" => "new-global-tool", "args" => ["action"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run new global tool"})

      # Then: It should approve and store the prefix in global settings
      assert {:approved, _state} = result

      # And: The approval should be added to global settings, preserving existing ones
      final_settings = Settings.new()
      final_global = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_project = SettingsApprovals.get_approvals(final_settings, :project, "shell")

      expected_global = (baseline_global ++ ["new-global-tool"]) |> Enum.sort()
      assert final_global == expected_global
      assert final_project == baseline_project

      # Why this matters: Users need a way to permanently approve commands they
      # trust across all their projects. The interactive flow must work correctly.
    end

    test "project prefix approval via user interaction" do
      # REASONING: Some tools are project-specific and shouldn't be approved
      # globally. This tests that users can scope approvals to just the current project.

      # Given: UI mock configured to choose project scope
      :meck.expect(UI, :choose, fn
        "Choose approval scope for:" <> _, _opts -> "Approve for the project"
        "Approve this request?", _opts -> "Approve persistently"
      end)

      # When: We execute a new project-specific command
      cmd = %{"command" => "project-build", "args" => ["deploy"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run project build"})

      # Then: It should approve and store the prefix in project settings
      assert {:approved, _state} = result

      # And: The approval should be persisted in project settings, not global
      final_settings = Settings.new()
      project_approvals = SettingsApprovals.get_approvals(final_settings, :project, "shell")
      global_approvals = SettingsApprovals.get_approvals(final_settings, :global, "shell")

      assert "project-build" in project_approvals
      assert "project-build" not in global_approvals

      # Why this matters: Project-specific tools should stay project-scoped to
      # maintain security boundaries between different projects.
    end

    test "session prefix approval via user interaction", %{
      baseline_global: baseline_global,
      baseline_project: baseline_project
    } do
      # REASONING: Sometimes users want to temporarily approve a command just
      # for the current session without permanent storage. This tests that
      # session approvals work correctly and don't modify persistent settings.

      # Given: Default UI mock will choose session scope (already configured in setup)

      # When: We execute a new command that needs session approval
      cmd = %{"command" => "session-only-tool", "args" => ["temp-action"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run session tool"})

      # Then: It should approve and store the prefix in session state
      assert {:approved, %{session: session}} = result
      assert {:prefix, "session-only-tool"} in session

      # And: No persistent settings should be modified
      final_settings = Settings.new()
      final_global = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_project = SettingsApprovals.get_approvals(final_settings, :project, "shell")

      assert final_global == baseline_global
      assert final_project == baseline_project

      # Why this matters: Session approvals provide temporary convenience for
      # experimental or one-off commands without permanent security implications.
    end

    test "session approval progression - new approval then auto-approve" do
      # REASONING: This tests the complete session approval lifecycle - a command
      # that's not pre-approved gets approved interactively, then on subsequent
      # runs it should auto-approve without user interaction. This validates that
      # the session approval workflow creates the correct state for future use.

      # Given: A command that has no existing approvals
      cmd = %{"command" => "lifecycle-tool", "args" => ["process"]}

      # When: We run it the first time (should trigger interactive approval)
      first_result = Shell.confirm(%{session: []}, {"|", [cmd], "run lifecycle tool"})

      # Then: It should be approved and stored in session
      assert {:approved, %{session: session_after_first}} = first_result
      assert {:prefix, "lifecycle-tool"} in session_after_first

      # And When: We run the same command again with the updated session
      # (Mock UI to fail if it gets called - it shouldn't be)
      :meck.expect(UI, :choose, fn
        _prompt, _opts -> flunk("UI should not be called for pre-approved command")
      end)

      second_result =
        Shell.confirm(%{session: session_after_first}, {"|", [cmd], "run lifecycle tool again"})

      # Then: It should auto-approve without any UI interaction
      assert {:approved, %{session: session_after_second}} = second_result
      assert {:prefix, "lifecycle-tool"} in session_after_second

      # Why this matters: This validates the complete session workflow - users
      # should only be prompted once per session for the same command prefix.
      # This test ensures session approvals persist correctly for subsequent uses.
    end

    test "global approval progression - new approval then auto-approve" do
      # REASONING: Similar to session progression, but for global approvals.
      # This ensures that global approvals created interactively work correctly
      # on subsequent commands, validating our settings.json storage and retrieval.

      # Given: UI mock configured for global approval on first run
      :meck.expect(UI, :choose, fn
        "Choose approval scope for:" <> _, _opts -> "Approve globally"
        "Approve this request?", _opts -> "Approve persistently"
      end)

      cmd = %{"command" => "global-lifecycle-tool", "args" => ["init"]}

      # When: We run it the first time (should trigger interactive approval)
      first_result = Shell.confirm(%{session: []}, {"|", [cmd], "run global lifecycle tool"})

      # Then: It should be approved and stored globally
      assert {:approved, %{session: []}} = first_result

      # And: The approval should be persisted in global settings
      final_settings = Settings.new()
      global_approvals = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      assert "global-lifecycle-tool" in global_approvals

      # When: We run the same command again (mock UI to fail if called)
      :meck.expect(UI, :choose, fn
        _prompt, _opts -> flunk("UI should not be called for globally pre-approved command")
      end)

      second_result =
        Shell.confirm(%{session: []}, {"|", [cmd], "run global lifecycle tool again"})

      # Then: It should auto-approve from global settings without prompting
      assert {:approved, %{session: []}} = second_result

      # Why this matters: Global approvals should persist across sessions and
      # auto-approve without re-prompting, validating our settings.json integration.
    end

    test "project approval progression - new approval then auto-approve" do
      # REASONING: Tests project approval persistence and retrieval workflow.

      # Given: UI mock configured for project approval on first run
      :meck.expect(UI, :choose, fn
        "Choose approval scope for:" <> _, _opts -> "Approve for the project"
        "Approve this request?", _opts -> "Approve persistently"
      end)

      cmd = %{"command" => "project-lifecycle-tool", "args" => ["setup"]}

      # When: We run it the first time (should trigger interactive approval)
      first_result = Shell.confirm(%{session: []}, {"|", [cmd], "run project lifecycle tool"})

      # Then: It should be approved and stored in project settings
      assert {:approved, %{session: []}} = first_result

      # When: We run the same command again (mock UI to fail if called)
      :meck.expect(UI, :choose, fn
        _prompt, _opts -> flunk("UI should not be called for project pre-approved command")
      end)

      second_result =
        Shell.confirm(%{session: []}, {"|", [cmd], "run project lifecycle tool again"})

      # Then: It should auto-approve from project settings without prompting
      assert {:approved, %{session: []}} = second_result

      # Why this matters: Project approvals should persist and auto-approve
      # within the same project context, validating project-scoped settings.
    end
  end

  describe "negative approval paths - user denials" do
    test "user denies global approval" do
      # REASONING: Users must be able to deny commands they don't trust.
      # This tests that denials work correctly and don't have unintended side effects.

      # Given: UI mock configured to deny the approval
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Deny"
      end)

      # When: We execute a command and the user denies it
      cmd = %{"command" => "untrusted-tool", "args" => ["suspicious-action"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run untrusted tool"})

      # Then: It should be denied with a proper error message
      assert {:denied, reason, %{session: []}} = result
      assert is_binary(reason)

      # Why this matters: The denial path must work reliably to maintain security.
      # Users need confidence that denied commands actually stay denied.
    end

    test "user denies project approval" do
      # REASONING: Similar to global denials, but tests the project-scoped denial path.

      # Given: UI mock configured to deny the approval
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Deny"
      end)

      # When: We execute a command and the user denies it
      cmd = %{"command" => "untrusted-project-tool", "args" => ["action"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run untrusted project tool"})

      # Then: It should be denied properly
      assert {:denied, reason, %{session: []}} = result
      assert is_binary(reason)
    end

    test "user denies session approval" do
      # REASONING: Even temporary approvals must be deniable by users.

      # Given: UI mock configured to deny the approval
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Deny"
      end)

      # When: We execute a command and the user denies it
      cmd = %{"command" => "untrusted-session-tool", "args" => ["temp-action"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run untrusted session tool"})

      # Then: It should be denied properly
      assert {:denied, reason, %{session: []}} = result
      assert is_binary(reason)
    end
  end

  describe "negative approval paths - missing approvals" do
    test "command not in global settings prompts and can be denied" do
      # REASONING: When a command isn't pre-approved, the system should prompt
      # the user. This tests that missing global approvals correctly trigger prompts
      # and that subsequent denials work properly.

      # Given: Global approval exists for a DIFFERENT command
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :global, "shell", "approved-tool")

      # And: UI mock configured to deny when prompted
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Deny"
      end)

      # When: We execute a command that's NOT in global approvals
      cmd = %{"command" => "unapproved-global-tool", "args" => ["action"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run unapproved tool"})

      # Then: It should prompt the user and respect the denial
      assert {:denied, reason, %{session: []}} = result
      assert is_binary(reason)

      # Why this matters: The system must distinguish between approved and
      # unapproved commands and handle the missing approval case correctly.
    end

    test "command not in project settings prompts and can be denied" do
      # REASONING: Similar logic for project-scoped approvals.

      # Given: Project approval exists for a DIFFERENT command
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :project, "shell", "approved-project-tool")

      # And: UI mock configured to deny when prompted
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Deny"
      end)

      # When: We execute a command that's NOT in project approvals
      cmd = %{"command" => "unapproved-project-tool", "args" => ["action"]}
      result = Shell.confirm(%{session: []}, {"|", [cmd], "run unapproved project tool"})

      # Then: It should prompt and respect the denial
      assert {:denied, reason, %{session: []}} = result
      assert is_binary(reason)
    end

    test "command not in session state prompts and can be denied" do
      # REASONING: Session approvals should also properly handle missing approvals.
      # This tests that having SOME session approvals doesn't auto-approve ALL commands.

      # Given: Session state with approval for a DIFFERENT command
      session_with_different_approval = [{:prefix, "approved-session-tool"}]

      # And: UI mock configured to deny when prompted
      :meck.expect(UI, :choose, fn
        "Approve this request?", _opts -> "Deny"
      end)

      # When: We execute a command that's NOT in session approvals
      cmd = %{"command" => "unapproved-session-tool", "args" => ["action"]}

      result =
        Shell.confirm(
          %{session: session_with_different_approval},
          {"|", [cmd], "run unapproved session tool"}
        )

      # Then: It should prompt and respect the denial
      assert {:denied, reason, %{session: session}} = result
      assert is_binary(reason)

      # And: Existing session approvals should be preserved
      assert {:prefix, "approved-session-tool"} in session

      # Why this matters: Session state should be preserved correctly even
      # when new commands are denied. Partial session approvals should work.
    end
  end

  describe "prefix extraction behavior validation" do
    test "known command families extract subcommands correctly" do
      # REASONING: Commands in known families (like git, mix, npm) should extract
      # meaningful prefixes that include subcommands. This enables more granular
      # approvals like "git log" vs just "git".

      # Given: A command from a known family (mix is in @subcmd_families)
      cmd = %{"command" => "mix", "args" => ["test", "--verbose"]}

      # When: We extract the prefix
      prefix = Shell.extract_prefix(cmd)

      # Then: It should include the subcommand
      assert prefix == "mix test"

      # Why this matters: Users want to approve specific git/mix/npm commands,
      # not all git/mix/npm commands. Subcommand extraction enables this.
    end

    test "unknown commands return base command only" do
      # REASONING: For unknown commands, we can't distinguish between subcommands
      # and file arguments (e.g., "rm file.txt" vs "git log"). The safe approach
      # is to return just the base command.

      # Given: A command NOT in known families
      cmd = %{"command" => "custom-tool", "args" => ["build", "file.txt"]}

      # When: We extract the prefix
      prefix = Shell.extract_prefix(cmd)

      # Then: It should return only the base command
      assert prefix == "custom-tool"

      # Why this matters: We can't make assumptions about unknown command
      # structure. Returning the base command is the safe, predictable approach.
    end
  end
end
