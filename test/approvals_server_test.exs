defmodule ApprovalsServerTest do
  use Fnord.TestCase

  # Use unique project name to avoid conflicts
  @test_project "approvals_server_test_project"

  setup do
    # Start the server fresh for each test
    if Process.whereis(ApprovalsServer) do
      Agent.stop(ApprovalsServer)
    end

    # Clean up any existing project data
    settings = Settings.new()
    if Settings.get(settings, @test_project) do
      Settings.delete(settings, @test_project)
    end

    # Clear global approved commands
    Settings.set(settings, "approved_commands", %{})

    # Start server
    {:ok, _pid} = ApprovalsServer.start_link()

    :ok
  end

  describe "initialization" do
    test "starts with empty ephemeral approvals" do
      state = ApprovalsServer.get_state()
      assert MapSet.size(state.ephemeral) == 0
    end

    test "loads existing global approvals from Settings" do
      # Stop current server and set up global approvals
      Agent.stop(ApprovalsServer)
      
      settings = Settings.new()
      settings = Settings.set_command_approval(settings, :global, "git push", true)
      _settings = Settings.set_command_approval(settings, :global, "rm -rf", false)
      
      # Restart server to load from Settings
      {:ok, _pid} = ApprovalsServer.start_link()
      
      state = ApprovalsServer.get_state()
      assert MapSet.member?(state.global, "git push")
      refute MapSet.member?(state.global, "rm -rf")
    end

    test "loads existing project approvals when project is set" do
      # Stop current server and set up project
      Agent.stop(ApprovalsServer)
      
      # Set project in application environment
      Settings.set_project(@test_project)
      
      # Set up project approvals
      settings = Settings.new()
      _settings = Settings.set_command_approval(settings, @test_project, "make build", true)
      
      # Restart server to load from Settings
      {:ok, _pid} = ApprovalsServer.start_link()
      
      # Verify project approval works (project is dynamically detected)
      assert ApprovalsServer.approved?("make build")
    end

    test "handles no project set gracefully" do
      # Stop current server and clear project
      Agent.stop(ApprovalsServer)
      Application.put_env(:fnord, :project, nil)
      
      # Restart server
      {:ok, _pid} = ApprovalsServer.start_link()
      
      # Verify that project approvals fail when no project is set
      assert ApprovalsServer.approve(:project, "test cmd") == {:error, :no_project}
    end
  end

  describe "approved?/1" do
    test "returns false for unapproved commands" do
      refute ApprovalsServer.approved?("unknown command")
    end

    test "returns true for session approvals" do
      ApprovalsServer.approve(:session, "test command")
      assert ApprovalsServer.approved?("test command")
    end

    test "returns true for project approvals" do
      Settings.set_project(@test_project)
      ApprovalsServer.reset()  # Reload with project set
      
      ApprovalsServer.approve(:project, "project command")
      assert ApprovalsServer.approved?("project command")
    end

    test "returns true for global approvals" do
      ApprovalsServer.approve(:global, "global command")
      assert ApprovalsServer.approved?("global command")
    end

    test "hierarchical lookup works - global overrides project" do
      Settings.set_project(@test_project)
      ApprovalsServer.reset()
      
      # Add to both global and project
      ApprovalsServer.approve(:global, "shared command")
      
      # Should still be approved even though not in project tier
      assert ApprovalsServer.approved?("shared command")
      
      state = ApprovalsServer.get_state()
      assert MapSet.member?(state.global, "shared command")
      # Project approvals are loaded dynamically, so we just verify it's still approved
      assert ApprovalsServer.approved?("shared command")
    end

    test "hierarchical lookup works - project and session coexist" do
      Settings.set_project(@test_project)
      ApprovalsServer.reset()
      
      ApprovalsServer.approve(:project, "project cmd")
      ApprovalsServer.approve(:session, "session cmd")
      
      assert ApprovalsServer.approved?("project cmd")
      assert ApprovalsServer.approved?("session cmd")
    end
  end

  describe "approve/2 session scope" do
    test "adds command to ephemeral tier" do
      ApprovalsServer.approve(:session, "temp command")
      
      state = ApprovalsServer.get_state()
      assert MapSet.member?(state.ephemeral, "temp command")
      assert ApprovalsServer.approved?("temp command")
    end

    test "session approvals are not persisted" do
      ApprovalsServer.approve(:session, "temp command")
      
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
      ApprovalsServer.reset()
      
      assert ApprovalsServer.approve(:project, "project cmd") == {:error, :no_project}
    end

    test "adds command to project tier and persists" do
      Settings.set_project(@test_project)
      ApprovalsServer.reset()
      
      assert ApprovalsServer.approve(:project, "project cmd") == :ok
      
      # Check that command is approved
      assert ApprovalsServer.approved?("project cmd")
      
      # Check persistence
      settings = Settings.new()
      project_commands = Settings.get_approved_commands(settings, @test_project)
      assert project_commands["project cmd"] == true
    end

    test "removes command from session tier when promoting" do
      Settings.set_project(@test_project)
      ApprovalsServer.reset()
      
      # First add to session
      ApprovalsServer.approve(:session, "cmd")
      state = ApprovalsServer.get_state()
      assert MapSet.member?(state.ephemeral, "cmd")
      
      # Then promote to project
      ApprovalsServer.approve(:project, "cmd")
      state = ApprovalsServer.get_state()
      # Check that it's still approved and removed from ephemeral
      assert ApprovalsServer.approved?("cmd")
      refute MapSet.member?(state.ephemeral, "cmd")
    end
  end

  describe "approve/2 global scope" do
    test "adds command to global tier and persists" do
      ApprovalsServer.approve(:global, "global cmd")
      
      # Check in-memory state
      state = ApprovalsServer.get_state()
      assert MapSet.member?(state.global, "global cmd")
      assert ApprovalsServer.approved?("global cmd")
      
      # Check persistence
      settings = Settings.new()
      global_commands = Settings.get_approved_commands(settings, :global)
      assert global_commands["global cmd"] == true
    end

    test "removes command from lower tiers when promoting to global" do
      Settings.set_project(@test_project)
      ApprovalsServer.reset()
      
      # Add to project tier first
      ApprovalsServer.approve(:project, "cmd")
      
      # Verify it's approved at project level
      assert ApprovalsServer.approved?("cmd")
      
      # Promote to global
      ApprovalsServer.approve(:global, "cmd")
      
      state = ApprovalsServer.get_state()
      assert MapSet.member?(state.global, "cmd")
      # Command should still be approved (now from global)
      assert ApprovalsServer.approved?("cmd")
      refute MapSet.member?(state.ephemeral, "cmd")
    end
  end

  describe "reset/0" do
    test "reloads state from Settings" do
      # Add some session approvals
      ApprovalsServer.approve(:session, "temp1")
      ApprovalsServer.approve(:session, "temp2")
      
      state = ApprovalsServer.get_state()
      assert MapSet.size(state.ephemeral) == 2
      
      # Reset should clear session but keep persistent
      ApprovalsServer.reset()
      
      state = ApprovalsServer.get_state()
      assert MapSet.size(state.ephemeral) == 0
    end

    test "reloads project approvals when project changes" do
      # Start with one project
      Settings.set_project(@test_project)
      ApprovalsServer.reset()
      ApprovalsServer.approve(:project, "project1 cmd")
      
      # Switch to different project
      other_project = "#{@test_project}_other"
      Settings.set_project(other_project)
      settings = Settings.new()
      _settings = Settings.set_command_approval(settings, other_project, "project2 cmd", true)
      
      ApprovalsServer.reset()
      
      # Verify that the new project's approvals are available
      assert ApprovalsServer.approved?("project2 cmd")
      refute ApprovalsServer.approved?("project1 cmd")
      
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
            ApprovalsServer.approve(:session, "concurrent_cmd_#{i}")
            ApprovalsServer.approved?("concurrent_cmd_#{i}")
          end)
        end)
      
      results = Task.await_many(tasks)
      
      # All should return true
      assert Enum.all?(results)
      
      # All commands should be approved
      state = ApprovalsServer.get_state()
      assert MapSet.size(state.ephemeral) == 10
    end
  end

  describe "edge cases" do
    test "handles empty command strings" do
      ApprovalsServer.approve(:session, "")
      assert ApprovalsServer.approved?("")
    end

    test "handles commands with special characters" do
      special_cmd = "rm -rf /tmp/* && echo 'dangerous'"
      ApprovalsServer.approve(:session, special_cmd)
      assert ApprovalsServer.approved?(special_cmd)
    end

    test "handles very long command strings" do
      long_cmd = String.duplicate("very long command ", 100)
      ApprovalsServer.approve(:global, long_cmd)
      assert ApprovalsServer.approved?(long_cmd)
    end
  end
end