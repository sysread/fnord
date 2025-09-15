defmodule Services.Approvals.Shell.IntegrationTest do
  @moduledoc """
  Integration test suite for Services.Approvals.Shell + Settings.Approvals interaction.

  This test suite validates the complete integration between persistent approvals
  stored in settings.json (Settings.Approvals) and the runtime workflow behavior
  (Services.Approvals.Shell). The focus is on how pre-existing persistent approvals
  affect the different approval workflow paths.

  ## Integration Test Philosophy

  Each test establishes a specific pre-existing approval state in settings.json,
  then validates how Services.Approvals.Shell workflows behave given that state:

  1. **Auto-approval scenarios**: Commands that should match existing approvals
  2. **Interactive scenarios**: Commands requiring user interaction despite existing approvals
  3. **Scope precedence**: How global vs project approvals interact
  4. **Mixed approval types**: Integration between prefix and regex approvals
  5. **Session state layering**: How session approvals layer on top of persistent ones

  ## Test Matrix Coverage

  The test matrix covers these key dimensions:

  **Pre-existing Approval States:**
  - Clean state (no existing approvals)
  - Global prefix approvals only
  - Project prefix approvals only
  - Global regex approvals only
  - Project regex approvals only
  - Mixed prefix + regex at same scope
  - Mixed global + project approvals
  - Complex combinations of all types

  **Command Matching Scenarios:**
  - Exact prefix matches
  - Regex pattern matches
  - Multiple approval type matches
  - No matches (requiring interaction)
  - Partial/edge case matches

  **Workflow Integration Points:**
  - Auto-approval paths (bypass UI interaction)
  - Interactive approval paths (user choice flows)
  - Session state accumulation over multiple commands
  - Settings.json integrity preservation across operations
  """
  use Fnord.TestCase, async: false

  import Mox

  alias Services.Approvals.Shell
  alias Settings.Approvals, as: SettingsApprovals

  setup do
    # Use the REAL shell approval implementation for integration testing
    set_config(:approvals, %{
      edit: MockApprovals,
      shell: Services.Approvals.Shell
    })

    # Disable auto-approval settings to ensure predictable test conditions
    Settings.set_edit_mode(false)
    Settings.set_auto_approve(false)
    Settings.set_auto_policy(nil)

    # Create a real project for testing project-scoped approvals
    project = mock_project("integration-test")

    # Mock UI functions using Mox for better performance
    # UI.Output.Mock is already set up in Fnord.TestCase for UI.Output behaviour functions
    # However, UI.is_tty?/0 and UI.quiet?/0 are not part of UI.Output behaviour, so we use meck just for those
    :meck.new(UI, [:passthrough])
    :meck.expect(UI, :is_tty?, fn -> true end)
    :meck.expect(UI, :quiet?, fn -> false end)

    on_exit(fn ->
      try do
        :meck.unload(UI)
      rescue
        _ -> :ok
      end
    end)

    {:ok, project: project}
  end

  # ============================================================================
  # Auto-Approval Integration Tests
  # These test scenarios where existing persistent approvals should trigger
  # auto-approval without any user interaction
  # ============================================================================

  describe "auto-approval integration - prefix approvals" do
    test "global prefix approval auto-approves matching command" do
      # Given: Pre-existing global prefix approval
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :global, "shell", "git status")

      # When: Command matches the prefix
      cmd = %{"command" => "git", "args" => ["status", "--porcelain"]}

      # Then: Should auto-approve without UI interaction
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "git status check"})

      # Note: Auto-approval tests don't need UI mock expectations since no UI interaction occurs
    end

    test "project prefix approval auto-approves matching command" do
      # Given: Pre-existing project prefix approval
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :project, "shell", "npm test")

      # When: Command matches the project prefix
      cmd = %{"command" => "npm", "args" => ["test", "--coverage"]}

      # Then: Should auto-approve without UI interaction
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "npm test with coverage"})

      # Note: Auto-approval - no UI interaction expected
    end

    test "global prefix takes precedence when both global and project exist" do
      # Given: Both global and project prefix approvals for different patterns
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "make")
      _settings = SettingsApprovals.approve(settings, :project, "shell", "make test")

      # When: Command matches the broader global approval
      cmd = %{"command" => "make", "args" => ["build"]}

      # Then: Should auto-approve via global approval (doesn't require "make test")
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "make build"})

      # Note: Auto-approval - no UI interaction expected
    end
  end

  describe "auto-approval integration - regex approvals" do
    test "global regex approval auto-approves matching command" do
      # Given: Pre-existing global regex approval
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :global, "shell_full", "^git (status|diff|log)")

      # When: Command matches the regex pattern
      cmd = %{"command" => "git", "args" => ["diff", "--cached"]}

      # Then: Should auto-approve without UI interaction
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "git diff cached"})

      # Note: Auto-approval - no UI interaction expected
    end

    test "project regex approval auto-approves matching command" do
      # Given: Pre-existing project regex approval
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :project, "shell_full", "^mix (test|compile|deps\\.get)")

      # When: Command matches the project regex
      cmd = %{"command" => "mix", "args" => ["deps.get", "--force"]}

      # Then: Should auto-approve without UI interaction
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "mix deps.get force"})

      # Note: Auto-approval - no UI interaction expected
    end

    test "regex approval doesn't match - requires interaction" do
      # Given: Pre-existing regex that doesn't match the command
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :global, "shell_full", "^git (status|diff)")

      # When: Command doesn't match the regex (git push not in pattern)
      cmd = %{"command" => "git", "args" => ["push", "origin", "main"]}

      # Set up Mox expectation for user interaction
      expect(UI.Output.Mock, :choose, fn "Approve this request?", _opts -> "Approve" end)

      # Then: Should require user interaction (no auto-approval)
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "git push"})

      # Note: Mox will automatically verify the expected call was made
    end
  end

  # ============================================================================
  # Mixed Approval Type Integration Tests
  # These test scenarios where both prefix and regex approvals exist and
  # how the system prioritizes and applies them
  # ============================================================================

  describe "mixed approval types integration" do
    test "prefix approval matches when both prefix and regex exist" do
      # Given: Both prefix and regex approvals for similar commands
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "docker")
      _settings = SettingsApprovals.approve(settings, :global, "shell_full", "^docker (run|build)")

      # When: Command matches prefix (broader match)
      cmd = %{"command" => "docker", "args" => ["ps", "-a"]}

      # Then: Should auto-approve via prefix match (docker ps not in regex)
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "docker ps"})

      # Note: Auto-approval - no UI interaction expected
    end

    test "regex approval matches when prefix doesn't" do
      # Given: Specific prefix and broader regex approvals
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "kubectl get pods")
      _settings = SettingsApprovals.approve(settings, :global, "shell_full", "^kubectl (get|describe) .*")

      # When: Command matches regex but not specific prefix
      cmd = %{"command" => "kubectl", "args" => ["get", "services"]}

      # Then: Should auto-approve via regex match
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "kubectl get services"})

      # Note: Auto-approval - no UI interaction expected
    end

    test "no match in either prefix or regex requires interaction" do
      # Given: Both prefix and regex approvals that don't match
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "npm install")
      _settings = SettingsApprovals.approve(settings, :global, "shell_full", "^npm (test|build)")

      # When: Command matches neither approval type
      cmd = %{"command" => "npm", "args" => ["publish", "--access", "public"]}

      # Set up Mox expectation for user interaction
      expect(UI.Output.Mock, :choose, fn "Approve this request?", _opts -> "Approve" end)

      # Then: Should require user interaction
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "npm publish"})

      # Note: Mox will automatically verify the expected call was made
    end
  end

  # ============================================================================
  # Interactive Workflow Integration Tests
  # These test scenarios where user interaction is required and how that
  # integrates with existing persistent approvals
  # ============================================================================

  describe "interactive workflow integration" do
    test "new global approval integrates with existing project approvals" do
      # Given: Pre-existing approvals at BOTH global and project levels to test settings integrity
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "git status")
      settings = SettingsApprovals.approve(settings, :global, "shell_full", "^grep.*pattern")
      settings = SettingsApprovals.approve(settings, :project, "shell", "yarn test")
      initial_settings = SettingsApprovals.approve(settings, :project, "shell_full", "^npm (install|test)")

      # Capture baseline state to verify it's preserved
      initial_global_prefix = SettingsApprovals.get_approvals(initial_settings, :global, "shell")
      initial_global_regex = SettingsApprovals.get_approvals(initial_settings, :global, "shell_full")
      initial_project_prefix = SettingsApprovals.get_approvals(initial_settings, :project, "shell")
      initial_project_regex = SettingsApprovals.get_approvals(initial_settings, :project, "shell_full")

      # When: New command requires approval, user chooses global scope
      cmd = %{"command" => "yarn", "args" => ["build", "prod"]}

      # Set up Mox expectations for UI interactions
      expect(UI.Output.Mock, :choose, 2, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for: yarn build", _opts -> "Approve globally"
      end)

      expect(UI.Output.Mock, :prompt, fn _msg, _opts -> "" end)

      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "yarn build"})

      # Then: Verify settings.json integrity - ALL original approvals must be preserved
      final_settings = Settings.new()
      final_global_prefix = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_global_regex = SettingsApprovals.get_approvals(final_settings, :global, "shell_full")
      final_project_prefix = SettingsApprovals.get_approvals(final_settings, :project, "shell")
      final_project_regex = SettingsApprovals.get_approvals(final_settings, :project, "shell_full")

      # CRITICAL: All original approvals must still exist (regression test for settings corruption)
      assert Enum.all?(initial_global_prefix, &(&1 in final_global_prefix)),
        "Original global prefix approvals were lost: #{inspect(initial_global_prefix)} vs #{inspect(final_global_prefix)}"
      assert Enum.all?(initial_global_regex, &(&1 in final_global_regex)),
        "Original global regex approvals were lost: #{inspect(initial_global_regex)} vs #{inspect(final_global_regex)}"
      assert Enum.all?(initial_project_prefix, &(&1 in final_project_prefix)),
        "Original project prefix approvals were lost: #{inspect(initial_project_prefix)} vs #{inspect(final_project_prefix)}"
      assert Enum.all?(initial_project_regex, &(&1 in final_project_regex)),
        "Original project regex approvals were lost: #{inspect(initial_project_regex)} vs #{inspect(final_project_regex)}"

      # AND: New approval should appear in global scope
      assert "yarn build" in final_global_prefix, "New global approval was not added"

      # AND: Counts should increase by exactly 1 for global prefix
      assert length(final_global_prefix) == length(initial_global_prefix) + 1
      assert length(final_global_regex) == length(initial_global_regex)
      assert length(final_project_prefix) == length(initial_project_prefix)
      assert length(final_project_regex) == length(initial_project_regex)
    end

    test "new project approval integrates with existing global approvals" do
      # Given: Pre-existing approvals at BOTH global and project levels to test settings integrity
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "python -m pytest")
      settings = SettingsApprovals.approve(settings, :global, "shell_full", "^curl.*https")
      settings = SettingsApprovals.approve(settings, :project, "shell", "make build")
      initial_settings = SettingsApprovals.approve(settings, :project, "shell_full", "^docker (ps|images)")

      # Capture baseline state to verify it's preserved
      initial_global_prefix = SettingsApprovals.get_approvals(initial_settings, :global, "shell")
      initial_global_regex = SettingsApprovals.get_approvals(initial_settings, :global, "shell_full")
      initial_project_prefix = SettingsApprovals.get_approvals(initial_settings, :project, "shell")
      initial_project_regex = SettingsApprovals.get_approvals(initial_settings, :project, "shell_full")

      # When: New command, user chooses project scope
      cmd = %{"command" => "python", "args" => ["-m", "black", "."]}

      # Set up Mox expectations for UI interactions
      expect(UI.Output.Mock, :choose, 2, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for: python", _opts -> "Approve for the project"
      end)

      expect(UI.Output.Mock, :prompt, fn _msg, _opts -> "" end)

      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "python black"})

      # Then: Verify settings.json integrity - ALL original approvals must be preserved
      final_settings = Settings.new()
      final_global_prefix = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_global_regex = SettingsApprovals.get_approvals(final_settings, :global, "shell_full")
      final_project_prefix = SettingsApprovals.get_approvals(final_settings, :project, "shell")
      final_project_regex = SettingsApprovals.get_approvals(final_settings, :project, "shell_full")

      # CRITICAL: All original approvals must still exist (regression test for settings corruption)
      assert Enum.all?(initial_global_prefix, &(&1 in final_global_prefix)),
        "Original global prefix approvals were lost: #{inspect(initial_global_prefix)} vs #{inspect(final_global_prefix)}"
      assert Enum.all?(initial_global_regex, &(&1 in final_global_regex)),
        "Original global regex approvals were lost: #{inspect(initial_global_regex)} vs #{inspect(final_global_regex)}"
      assert Enum.all?(initial_project_prefix, &(&1 in final_project_prefix)),
        "Original project prefix approvals were lost: #{inspect(initial_project_prefix)} vs #{inspect(final_project_prefix)}"
      assert Enum.all?(initial_project_regex, &(&1 in final_project_regex)),
        "Original project regex approvals were lost: #{inspect(initial_project_regex)} vs #{inspect(final_project_regex)}"

      # AND: New approval should appear in project scope
      assert "python" in final_project_prefix, "New project approval was not added"

      # AND: Counts should increase by exactly 1 for project prefix
      assert length(final_global_prefix) == length(initial_global_prefix)
      assert length(final_global_regex) == length(initial_global_regex)
      assert length(final_project_prefix) == length(initial_project_prefix) + 1
      assert length(final_project_regex) == length(initial_project_regex)
    end

    test "session approval doesn't affect persistent storage" do
      # Given: Pre-existing approvals at BOTH global and project levels to test settings integrity
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "cargo test")
      settings = SettingsApprovals.approve(settings, :global, "shell_full", "^find.*-name")
      settings = SettingsApprovals.approve(settings, :project, "shell", "cargo build")
      initial_settings = SettingsApprovals.approve(settings, :project, "shell_full", "^helm (install|upgrade)")

      # Capture baseline state to verify session approval doesn't corrupt settings
      initial_global_prefix = SettingsApprovals.get_approvals(initial_settings, :global, "shell")
      initial_global_regex = SettingsApprovals.get_approvals(initial_settings, :global, "shell_full")
      initial_project_prefix = SettingsApprovals.get_approvals(initial_settings, :project, "shell")
      initial_project_regex = SettingsApprovals.get_approvals(initial_settings, :project, "shell_full")

      # When: User chooses session approval for new command
      cmd = %{"command" => "cargo", "args" => ["clippy"]}

      # Set up Mox expectations for UI interactions
      expect(UI.Output.Mock, :choose, 2, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for: cargo clippy", _opts -> "Approve for this session"
      end)

      expect(UI.Output.Mock, :prompt, fn _msg, _opts -> "" end)

      assert {:approved, new_state} = Shell.confirm(%{session: []}, {"|", [cmd], "cargo clippy"})

      # Then: Session state should contain new approval
      assert {:prefix, "cargo clippy"} in new_state.session

      # And: Persistent storage should be COMPLETELY unchanged (critical for session approval)
      final_settings = Settings.new()
      final_global_prefix = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_global_regex = SettingsApprovals.get_approvals(final_settings, :global, "shell_full")
      final_project_prefix = SettingsApprovals.get_approvals(final_settings, :project, "shell")
      final_project_regex = SettingsApprovals.get_approvals(final_settings, :project, "shell_full")

      # CRITICAL: Session approval must not modify settings.json at all
      assert final_global_prefix == initial_global_prefix,
        "Session approval corrupted global prefix: #{inspect(initial_global_prefix)} vs #{inspect(final_global_prefix)}"
      assert final_global_regex == initial_global_regex,
        "Session approval corrupted global regex: #{inspect(initial_global_regex)} vs #{inspect(final_global_regex)}"
      assert final_project_prefix == initial_project_prefix,
        "Session approval corrupted project prefix: #{inspect(initial_project_prefix)} vs #{inspect(final_project_prefix)}"
      assert final_project_regex == initial_project_regex,
        "Session approval corrupted project regex: #{inspect(initial_project_regex)} vs #{inspect(final_project_regex)}"

      # AND: Counts must remain exactly the same
      assert length(final_global_prefix) == length(initial_global_prefix)
      assert length(final_global_regex) == length(initial_global_regex)
      assert length(final_project_prefix) == length(initial_project_prefix)
      assert length(final_project_regex) == length(initial_project_regex)
    end
  end

  # ============================================================================
  # Session State Integration Tests
  # These test how session approvals layer on top of persistent approvals
  # and interact with the complete approval workflow
  # ============================================================================

  describe "session state layering integration" do
    test "session approval overrides persistent approval requirement" do
      # Given: No persistent approvals for command
      # And: Existing session approval
      initial_session = [{:prefix, "custom-tool"}]

      # When: Command matches session approval
      cmd = %{"command" => "custom-tool", "args" => ["action", "file"]}

      # Then: Should auto-approve based on session state
      assert {:approved, _state} = Shell.confirm(%{session: initial_session}, {"|", [cmd], "custom tool"})

      # Note: Auto-approval - no UI interaction expected
    end

    test "mixed session and persistent approvals work together" do
      # Given: Persistent approval for one command
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :global, "shell", "git status")

      # And: Session approval for different command
      initial_session = [{:prefix, "docker ps"}]

      # When: Testing both commands
      cmd1 = %{"command" => "git", "args" => ["status"]}
      cmd2 = %{"command" => "docker", "args" => ["ps"]}

      # Then: Both should auto-approve from their respective sources
      assert {:approved, state1} = Shell.confirm(%{session: initial_session}, {"|", [cmd1], "git check"})
      assert {:approved, _state2} = Shell.confirm(state1, {"|", [cmd2], "docker list"})

      # Note: Auto-approval - no UI interaction expected
    end

    test "session regex and persistent prefix approvals coexist" do
      # Given: Persistent prefix approval
      settings = Settings.new()
      _settings = SettingsApprovals.approve(settings, :global, "shell", "make")

      # And: Session regex approval
      initial_session = [{:full, "^gradle (clean|build|test).*"}]

      # When: Commands match their respective approval types
      cmd1 = %{"command" => "make", "args" => ["install"]}  # matches persistent prefix
      cmd2 = %{"command" => "gradle", "args" => ["clean"]}  # matches session regex

      # Then: Both should auto-approve
      assert {:approved, state1} = Shell.confirm(%{session: initial_session}, {"|", [cmd1], "make install"})
      assert {:approved, _state2} = Shell.confirm(state1, {"|", [cmd2], "gradle clean"})

      # Note: Auto-approval - no UI interaction expected
    end
  end

  # ============================================================================
  # Complex State Integration Tests
  # These test complex scenarios with multiple approval types across multiple
  # scopes to ensure the integration handles sophisticated real-world cases
  # ============================================================================

  describe "complex state integration" do
    test "comprehensive approval matrix - all types and scopes" do
      # Given: Complex pre-existing approval state
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "git")
      settings = SettingsApprovals.approve(settings, :global, "shell_full", "^npm (install|test)")
      settings = SettingsApprovals.approve(settings, :project, "shell", "python")  # Fixed: should match extracted prefix
      _settings = SettingsApprovals.approve(settings, :project, "shell_full", "^docker (run|build) .*")

      # And: Session state with mixed approvals
      initial_session = [
        {:prefix, "make clean"},
        {:full, "^cargo (check|test|build).*"}
      ]

      # When: Testing commands that match each approval type/scope
      test_cases = [
        # Global prefix: git
        {%{"command" => "git", "args" => ["branch"]}, "should match global prefix"},
        # Global regex: npm install|test
        {%{"command" => "npm", "args" => ["install", "lodash"]}, "should match global regex"},
        # Project prefix: python -m pytest
        {%{"command" => "python", "args" => ["-m", "pytest", "tests/"]}, "should match project prefix"},
        # Project regex: docker run|build
        {%{"command" => "docker", "args" => ["run", "-it", "ubuntu"]}, "should match project regex"},
        # Session prefix: make
        {%{"command" => "make", "args" => ["clean"]}, "should match session prefix"},
        # Session regex: cargo check|test|build
        {%{"command" => "cargo", "args" => ["test", "--release"]}, "should match session regex"}
      ]

      # Then: All should auto-approve without user interaction
      final_state = Enum.reduce(test_cases, %{session: initial_session}, fn {cmd, description}, state ->
        assert {:approved, new_state} = Shell.confirm(state, {"|", [cmd], description})
        new_state
      end)

      # Verify no UI interaction occurred for any command
      # Note: Auto-approval - no UI interaction expected

      # And: Session state should be preserved
      assert length(final_state.session) >= 2  # Original session approvals still there
    end

    test "approval precedence with overlapping patterns" do
      # Given: Overlapping approval patterns at different scopes
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "kubectl")  # Broad global
      settings = SettingsApprovals.approve(settings, :project, "shell", "kubectl get")  # Specific project
      _settings = SettingsApprovals.approve(settings, :project, "shell_full", "^kubectl get pods.*")  # Very specific project regex

      # When: Command could match multiple patterns
      cmd = %{"command" => "kubectl", "args" => ["get", "pods", "-o", "wide"]}

      # Then: Should auto-approve (any match is sufficient)
      assert {:approved, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "kubectl get pods wide"})

      # Note: Auto-approval - no UI interaction expected
    end

    test "integration preserves settings.json integrity across operations" do
      # Given: Complex initial state
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "baseline-cmd")
      initial_settings = SettingsApprovals.approve(settings, :project, "shell_full", "^baseline-regex")

      # Capture initial approval counts
      initial_global_prefix = SettingsApprovals.get_approvals(initial_settings, :global, "shell")
      initial_project_regex = SettingsApprovals.get_approvals(initial_settings, :project, "shell_full")

      # When: Multiple interactive approvals occur
      cmd1 = %{"command" => "new-cmd1", "args" => []}
      cmd2 = %{"command" => "new-cmd2", "args" => []}

      # Set up Mox expectations for multiple UI interactions
      expect(UI.Output.Mock, :choose, 4, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for: new-cmd1", _opts -> "Approve globally"
        "Choose approval scope for: new-cmd2", _opts -> "Approve for the project"
      end)

      expect(UI.Output.Mock, :prompt, 2, fn
        msg, _opts ->
          cond do
            String.contains?(msg, "new-cmd1") -> "/^new-cmd1.*/"
            String.contains?(msg, "new-cmd2") -> "/^new-cmd2.*/"
            true -> "/^new-cmd.*/"
          end
      end)

      assert {:approved, state1} = Shell.confirm(%{session: []}, {"|", [cmd1], "first new command"})
      assert {:approved, _state2} = Shell.confirm(state1, {"|", [cmd2], "second new command"})

      # Then: All original approvals should be preserved
      final_settings = Settings.new()
      final_global_prefix = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_project_regex = SettingsApprovals.get_approvals(final_settings, :project, "shell_full")
      final_global_regex = SettingsApprovals.get_approvals(final_settings, :global, "shell_full")

      # Original approvals preserved
      assert Enum.all?(initial_global_prefix, &(&1 in final_global_prefix))
      assert Enum.all?(initial_project_regex, &(&1 in final_project_regex))

      # New approvals added correctly
      assert "^new-cmd1.*" in final_global_regex
      assert "^new-cmd2.*" in final_project_regex

      # Total counts increased appropriately
      assert length(final_global_prefix) == length(initial_global_prefix)
      assert length(final_project_regex) == length(initial_project_regex) + 1
      assert length(final_global_regex) == 1
    end
  end

  # ============================================================================
  # Denial Scenario Integration Tests
  # These test that denial scenarios preserve settings.json integrity and
  # don't accidentally add approvals when the user denies
  # ============================================================================

  describe "denial scenario integration" do
    test "user denial preserves all existing approvals without adding new ones" do
      # Given: Pre-existing approvals at BOTH global and project levels
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "git status")
      settings = SettingsApprovals.approve(settings, :global, "shell_full", "^ls.*-l")
      settings = SettingsApprovals.approve(settings, :project, "shell", "npm test")
      initial_settings = SettingsApprovals.approve(settings, :project, "shell_full", "^pytest.*-v")

      # Capture baseline state to verify denial doesn't corrupt settings
      initial_global_prefix = SettingsApprovals.get_approvals(initial_settings, :global, "shell")
      initial_global_regex = SettingsApprovals.get_approvals(initial_settings, :global, "shell_full")
      initial_project_prefix = SettingsApprovals.get_approvals(initial_settings, :project, "shell")
      initial_project_regex = SettingsApprovals.get_approvals(initial_settings, :project, "shell_full")

      # When: User denies approval for new command
      cmd = %{"command" => "dangerous-command", "args" => ["--delete-all"]}

      # Set up Mox expectation for denial
      expect(UI.Output.Mock, :choose, fn "Approve this request?", _opts -> "Deny" end)

      assert {:denied, _reason, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "dangerous operation"})

      # Then: Settings.json must be COMPLETELY unchanged (denial must not corrupt settings)
      final_settings = Settings.new()
      final_global_prefix = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_global_regex = SettingsApprovals.get_approvals(final_settings, :global, "shell_full")
      final_project_prefix = SettingsApprovals.get_approvals(final_settings, :project, "shell")
      final_project_regex = SettingsApprovals.get_approvals(final_settings, :project, "shell_full")

      # CRITICAL: Denial must not corrupt any existing approvals
      assert final_global_prefix == initial_global_prefix,
        "Denial corrupted global prefix: #{inspect(initial_global_prefix)} vs #{inspect(final_global_prefix)}"
      assert final_global_regex == initial_global_regex,
        "Denial corrupted global regex: #{inspect(initial_global_regex)} vs #{inspect(final_global_regex)}"
      assert final_project_prefix == initial_project_prefix,
        "Denial corrupted project prefix: #{inspect(initial_project_prefix)} vs #{inspect(final_project_prefix)}"
      assert final_project_regex == initial_project_regex,
        "Denial corrupted project regex: #{inspect(initial_project_regex)} vs #{inspect(final_project_regex)}"

      # AND: No new approvals should be added
      assert length(final_global_prefix) == length(initial_global_prefix)
      assert length(final_global_regex) == length(initial_global_regex)
      assert length(final_project_prefix) == length(initial_project_prefix)
      assert length(final_project_regex) == length(initial_project_regex)

      # AND: Denied command should not appear anywhere
      refute "dangerous-command" in final_global_prefix
      refute "dangerous-command" in final_project_prefix
    end

    test "user denial with feedback preserves settings integrity" do
      # Given: Pre-existing approvals at BOTH global and project levels
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "safe-command")
      settings = SettingsApprovals.approve(settings, :global, "shell_full", "^echo.*hello")
      settings = SettingsApprovals.approve(settings, :project, "shell", "test-runner")
      initial_settings = SettingsApprovals.approve(settings, :project, "shell_full", "^linter.*--fix")

      # Capture baseline state
      initial_global_prefix = SettingsApprovals.get_approvals(initial_settings, :global, "shell")
      initial_global_regex = SettingsApprovals.get_approvals(initial_settings, :global, "shell_full")
      initial_project_prefix = SettingsApprovals.get_approvals(initial_settings, :project, "shell")
      initial_project_regex = SettingsApprovals.get_approvals(initial_settings, :project, "shell_full")

      # When: User denies with feedback
      cmd = %{"command" => "risky-operation", "args" => ["--force"]}

      # Set up Mox expectations for denial with feedback
      expect(UI.Output.Mock, :choose, fn "Approve this request?", _opts -> "Deny with feedback" end)
      expect(UI.Output.Mock, :prompt, fn "Feedback:", _opts -> "This command looks too dangerous" end)

      assert {:denied, _reason, _state} = Shell.confirm(%{session: []}, {"|", [cmd], "risky operation"})

      # Then: Settings.json must be completely unchanged despite feedback collection
      final_settings = Settings.new()
      final_global_prefix = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_global_regex = SettingsApprovals.get_approvals(final_settings, :global, "shell_full")
      final_project_prefix = SettingsApprovals.get_approvals(final_settings, :project, "shell")
      final_project_regex = SettingsApprovals.get_approvals(final_settings, :project, "shell_full")

      # CRITICAL: Denial with feedback must not corrupt any settings
      assert final_global_prefix == initial_global_prefix
      assert final_global_regex == initial_global_regex
      assert final_project_prefix == initial_project_prefix
      assert final_project_regex == initial_project_regex

      # AND: All counts remain the same
      assert length(final_global_prefix) == length(initial_global_prefix)
      assert length(final_global_regex) == length(initial_global_regex)
      assert length(final_project_prefix) == length(initial_project_prefix)
      assert length(final_project_regex) == length(initial_project_regex)
    end

    test "mixed approval and denial operations preserve settings integrity" do
      # Given: Pre-existing comprehensive approval state
      settings = Settings.new()
      settings = SettingsApprovals.approve(settings, :global, "shell", "git")
      settings = SettingsApprovals.approve(settings, :global, "shell_full", "^aws.*s3")
      settings = SettingsApprovals.approve(settings, :project, "shell", "build-tool")
      initial_settings = SettingsApprovals.approve(settings, :project, "shell_full", "^deploy.*staging")

      # Capture initial state
      initial_global_prefix = SettingsApprovals.get_approvals(initial_settings, :global, "shell")
      initial_global_regex = SettingsApprovals.get_approvals(initial_settings, :global, "shell_full")
      initial_project_prefix = SettingsApprovals.get_approvals(initial_settings, :project, "shell")
      initial_project_regex = SettingsApprovals.get_approvals(initial_settings, :project, "shell_full")

      # When: Mixed scenario - approve one command, deny another
      cmd1 = %{"command" => "safe-new-tool", "args" => ["--help"]}
      cmd2 = %{"command" => "dangerous-tool", "args" => ["--delete-everything"]}

      # Set up Mox expectations for first interaction: Approve globally
      expect(UI.Output.Mock, :choose, 2, fn
        "Approve this request?", _opts -> "Approve persistently"
        "Choose approval scope for: safe-new-tool", _opts -> "Approve globally"
      end)

      expect(UI.Output.Mock, :prompt, fn _msg, _opts -> "" end)

      assert {:approved, state1} = Shell.confirm(%{session: []}, {"|", [cmd1], "safe operation"})

      # Set up Mox expectation for second interaction: Deny
      expect(UI.Output.Mock, :choose, fn "Approve this request?", _opts -> "Deny" end)

      assert {:denied, _reason, _final_state} = Shell.confirm(state1, {"|", [cmd2], "dangerous operation"})

      # Then: Settings should contain original approvals + the approved one, but not the denied one
      final_settings = Settings.new()
      final_global_prefix = SettingsApprovals.get_approvals(final_settings, :global, "shell")
      final_global_regex = SettingsApprovals.get_approvals(final_settings, :global, "shell_full")
      final_project_prefix = SettingsApprovals.get_approvals(final_settings, :project, "shell")
      final_project_regex = SettingsApprovals.get_approvals(final_settings, :project, "shell_full")

      # CRITICAL: All original approvals must be preserved
      assert Enum.all?(initial_global_prefix, &(&1 in final_global_prefix))
      assert Enum.all?(initial_global_regex, &(&1 in final_global_regex))
      assert Enum.all?(initial_project_prefix, &(&1 in final_project_prefix))
      assert Enum.all?(initial_project_regex, &(&1 in final_project_regex))

      # AND: Approved command should be added
      assert "safe-new-tool" in final_global_prefix

      # AND: Denied command should NOT be added
      refute "dangerous-tool" in final_global_prefix
      refute "dangerous-tool" in final_project_prefix

      # AND: Counts should reflect only the approved addition
      assert length(final_global_prefix) == length(initial_global_prefix) + 1
      assert length(final_global_regex) == length(initial_global_regex)
      assert length(final_project_prefix) == length(initial_project_prefix)
      assert length(final_project_regex) == length(initial_project_regex)
    end
  end
end