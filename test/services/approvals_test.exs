defmodule Services.ApprovalsTest do
  use Fnord.TestCase, async: false

  # Use unique project name to avoid conflicts
  @test_project "approvals_server_test_project"

  setup do
    # Start the server fresh for each test
    if Process.whereis(Services.Approvals) do
      Agent.stop(Services.Approvals)
    end

    # Clean up any existing project data
    settings = Settings.new()

    if Settings.get(settings, @test_project) do
      Settings.delete(settings, @test_project)
    end

    # Clear global approved commands
    Settings.set(settings, "approved_commands", %{})

    # Start server
    {:ok, _pid} = Services.Approvals.start_link()

    :ok
  end

  describe "initialization" do
    test "starts with empty ephemeral approvals" do
      state = Services.Approvals.get_state()
      assert MapSet.size(state.ephemeral) == 0
    end

    test "loads existing global approvals from Settings" do
      # Stop current server and set up global approvals
      Agent.stop(Services.Approvals)

      settings = Settings.new()
      _settings = Settings.add_approved_command(settings, :global, "action", "git push")

      # Restart server to load from Settings
      {:ok, _pid} = Services.Approvals.start_link()

      state = Services.Approvals.get_state()

      assert MapSet.member?(state.global, "action#git push")
    end

    test "loads existing project approvals when project is set" do
      # Stop current server and set up project
      Agent.stop(Services.Approvals)

      # Set project in application environment
      Settings.set_project(@test_project)

      # Set up project approvals
      settings = Settings.new()
      _settings = Settings.add_approved_command(settings, @test_project, "action", "make build")

      # Restart server to load from Settings
      {:ok, _pid} = Services.Approvals.start_link()

      # Verify project approval works (project is dynamically detected)
      assert Services.Approvals.approved?("action#make build")
    end

    test "handles no project set gracefully" do
      # Stop current server and clear project
      Agent.stop(Services.Approvals)
      Application.put_env(:fnord, :project, nil)

      # Restart server
      {:ok, _pid} = Services.Approvals.start_link()

      # Verify that project approvals fail when no project is set
      assert Services.Approvals.approve(:project, "test cmd") == {:error, :no_project}
    end
  end

  describe "approved?/1" do
    test "returns false for unapproved commands" do
      refute Services.Approvals.approved?("unknown command")
    end

    test "returns true for session approvals" do
      Services.Approvals.approve(:session, "test command")
      assert Services.Approvals.approved?("test command")
    end

    test "returns true for project approvals" do
      Settings.set_project(@test_project)
      # Reload with project set
      Services.Approvals.reset()

      Services.Approvals.approve(:project, "project command")
      assert Services.Approvals.approved?("project command")
    end

    test "returns true for global approvals" do
      Services.Approvals.approve(:global, "global command")
      assert Services.Approvals.approved?("global command")
    end

    test "hierarchical lookup works - global overrides project" do
      Settings.set_project(@test_project)
      Services.Approvals.reset()

      # Add to both global and project
      Services.Approvals.approve(:global, "shared command")

      # Should still be approved even though not in project tier
      assert Services.Approvals.approved?("shared command")

      state = Services.Approvals.get_state()
      assert MapSet.member?(state.global, "shared command")
      # Project approvals are loaded dynamically, so we just verify it's still approved
      assert Services.Approvals.approved?("shared command")
    end

    test "hierarchical lookup works - project and session coexist" do
      Settings.set_project(@test_project)
      Services.Approvals.reset()

      Services.Approvals.approve(:project, "project cmd")
      Services.Approvals.approve(:session, "session cmd")

      assert Services.Approvals.approved?("project cmd")
      assert Services.Approvals.approved?("session cmd")
    end
  end

  describe "approve/2 session scope" do
    test "adds command to ephemeral tier" do
      Services.Approvals.approve(:session, "temp command")

      state = Services.Approvals.get_state()
      assert MapSet.member?(state.ephemeral, "temp command")
      assert Services.Approvals.approved?("temp command")
    end

    test "session approvals are not persisted" do
      Services.Approvals.approve(:session, "temp command")

      # Check that it's not in Settings
      settings = Settings.new()
      global_commands = Settings.get_approved_commands(settings, :global)
      refute Map.has_key?(global_commands, "temp command")
    end
  end

  describe "approve/2 project scope" do
    test "requires project to be set" do
      # Ensure no project is set
      Application.put_env(:fnord, :project, nil)
      Services.Approvals.reset()

      assert Services.Approvals.approve(:project, "project cmd") == {:error, :no_project}
    end

    test "adds command to project tier and persists" do
      Settings.set_project(@test_project)
      Services.Approvals.reset()

      assert Services.Approvals.approve(:project, "project cmd") == :ok

      # Check that command is approved
      assert Services.Approvals.approved?("project cmd")

      # Check persistence - new format: {"action": ["project cmd"]}
      settings = Settings.new()
      project_commands = Settings.get_approved_commands(settings, @test_project)
      assert "project cmd" in Map.get(project_commands, "action", [])
    end

    test "removes command from session tier when promoting" do
      Settings.set_project(@test_project)
      Services.Approvals.reset()

      # First add to session
      Services.Approvals.approve(:session, "cmd")
      state = Services.Approvals.get_state()
      assert MapSet.member?(state.ephemeral, "cmd")

      # Then promote to project
      Services.Approvals.approve(:project, "cmd")
      state = Services.Approvals.get_state()
      # Check that it's still approved and removed from ephemeral
      assert Services.Approvals.approved?("cmd")
      refute MapSet.member?(state.ephemeral, "cmd")
    end
  end

  describe "approve/2 global scope" do
    test "adds command to global tier and persists" do
      Services.Approvals.approve(:global, "global cmd")

      # Check in-memory state
      state = Services.Approvals.get_state()
      assert MapSet.member?(state.global, "global cmd")
      assert Services.Approvals.approved?("global cmd")

      # Check persistence - new format: {"action": ["global cmd"]}
      settings = Settings.new()
      global_commands = Settings.get_approved_commands(settings, :global)
      assert "global cmd" in Map.get(global_commands, "action", [])
    end

    test "removes command from lower tiers when promoting to global" do
      Settings.set_project(@test_project)
      Services.Approvals.reset()

      # Add to project tier first
      Services.Approvals.approve(:project, "cmd")

      # Verify it's approved at project level
      assert Services.Approvals.approved?("cmd")

      # Promote to global
      Services.Approvals.approve(:global, "cmd")

      state = Services.Approvals.get_state()
      assert MapSet.member?(state.global, "cmd")
      # Command should still be approved (now from global)
      assert Services.Approvals.approved?("cmd")
      refute MapSet.member?(state.ephemeral, "cmd")
    end
  end

  describe "reset/0" do
    test "reloads state from Settings" do
      # Add some session approvals
      Services.Approvals.approve(:session, "temp1")
      Services.Approvals.approve(:session, "temp2")

      state = Services.Approvals.get_state()
      assert MapSet.size(state.ephemeral) == 2

      # Reset should clear session but keep persistent
      Services.Approvals.reset()

      state = Services.Approvals.get_state()
      assert MapSet.size(state.ephemeral) == 0
    end

    test "reloads project approvals when project changes" do
      # Start with one project
      Settings.set_project(@test_project)
      Services.Approvals.reset()
      Services.Approvals.approve(:project, "project1 cmd")

      # Switch to different project
      other_project = "#{@test_project}_other"
      Settings.set_project(other_project)
      settings = Settings.new()
      _settings = Settings.add_approved_command(settings, other_project, "action", "project2 cmd")

      Services.Approvals.reset()

      # Verify that the new project's approvals are available
      assert Services.Approvals.approved?("action#project2 cmd")
      refute Services.Approvals.approved?("action#project1 cmd")

      # Clean up
      Settings.delete(settings, other_project)
    end
  end

  describe "concurrent access" do
    test "handles multiple processes safely" do
      # Simulate concurrent approvals
      tasks =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            Services.Approvals.approve(:session, "concurrent_cmd_#{i}")
            Services.Approvals.approved?("concurrent_cmd_#{i}")
          end)
        end)

      results = Task.await_many(tasks)

      # All should return true
      assert Enum.all?(results)

      # All commands should be approved
      state = Services.Approvals.get_state()
      assert MapSet.size(state.ephemeral) == 10
    end
  end

  describe "edge cases" do
    test "handles empty command strings" do
      Services.Approvals.approve(:session, "")
      assert Services.Approvals.approved?("")
    end

    test "handles commands with special characters" do
      special_cmd = "rm -rf /tmp/* && echo 'dangerous'"
      Services.Approvals.approve(:session, special_cmd)
      assert Services.Approvals.approved?(special_cmd)
    end

    test "handles very long command strings" do
      long_cmd = String.duplicate("very long command ", 100)
      Services.Approvals.approve(:global, long_cmd)
      assert Services.Approvals.approved?(long_cmd)
    end
  end
end
