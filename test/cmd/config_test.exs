defmodule Cmd.ConfigTest do
  use Fnord.TestCase

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  # Enable logger output for error testing  
  setup do
    old_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: old_level) end)
    :ok
  end

  describe "list command" do
    test "lists global configuration when no project specified" do
      settings = Settings.new()
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")
      _settings = Settings.add_approved_command(settings, :global, "shell_cmd", "rm -rf")

      output =
        capture_io(fn ->
          Cmd.Config.run([], [:list], [])
        end)

      decoded = Jason.decode!(output)
      approved_commands = decoded["approved_commands"]
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      assert "git push" in shell_commands
      assert "rm -rf" in shell_commands
    end

    test "lists project configuration when project specified" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      _settings = Settings.add_approved_command(settings, project.name, "shell_cmd", "make build")

      output =
        capture_io(fn ->
          Cmd.Config.run([project: project.name], [:list], [])
        end)

      decoded = Jason.decode!(output)
      approved_commands = Map.get(decoded, "approved_commands", %{})
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      assert "make build" in shell_commands
    end

    test "shows error for nonexistent project" do
      log =
        capture_log(fn ->
          Cmd.Config.run([project: "nonexistent"], [:list], [])
        end)

      assert log =~ "Project not found"
    end
  end

  describe "set command" do
    test "requires project option" do
      log =
        capture_log(fn ->
          Cmd.Config.run([], [:set], [])
        end)

      assert log =~ "Project option is required"
    end

    test "works with existing project" do
      project = mock_project("config_test_project")
      # Create store directory to make project exist in store
      File.mkdir_p!(project.store_path)
      File.write!(Path.join(project.store_path, "dummy.json"), "{}")

      new_root = "/new/path"

      capture_io(fn ->
        Cmd.Config.run([project: project.name, root: new_root], [:set], [])
      end)

      # Verify the change was applied
      {:ok, updated_project} = Store.get_project(project.name)
      assert updated_project.source_root == Path.expand(new_root)
    end

    test "shows error for nonexistent project" do
      log =
        capture_log(fn ->
          Cmd.Config.run([project: "nonexistent", root: "/test"], [:set], [])
        end)

      assert log =~ "does not exist"
    end
  end

  describe "approvals list" do
    test "shows global approved commands when no project specified" do
      settings = Settings.new()
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")
      _settings = Settings.add_approved_command(settings, :global, "shell_cmd", "rm -rf")

      output =
        capture_io(fn ->
          Cmd.Config.run([], [:approvals, :list], [])
        end)

      assert output =~ "Global approved commands:"
      # Check that both commands appear in tag#command format
      assert output =~ "shell_cmd#git push"
      assert output =~ "shell_cmd#rm -rf"
      assert output =~ "✓ approved"
    end

    test "shows empty global commands" do
      _settings = Settings.new()

      output =
        capture_io(fn ->
          Cmd.Config.run([], [:approvals, :list], [])
        end)

      assert output =~ "Global approved commands:"
      assert output =~ "(none)"
    end

    test "shows project approved commands with inheritance" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "rm -rf")
      _settings = Settings.add_approved_command(settings, project.name, "shell_cmd", "make build")

      output =
        capture_io(fn ->
          Cmd.Config.run([project: project.name], [:approvals, :list], [])
        end)

      assert output =~ "Project 'config_test_project' approved commands:"
      assert output =~ "shell_cmd#make build: ✓ approved"
      assert output =~ "Inherited from global:"
      assert output =~ "shell_cmd#git push: ✓ approved"
      assert output =~ "shell_cmd#rm -rf: ✓ approved"
    end

    test "shows project commands with empty project list" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      _settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")

      output =
        capture_io(fn ->
          Cmd.Config.run([project: project.name], [:approvals, :list], [])
        end)

      assert output =~ "Project 'config_test_project' approved commands:"
      assert output =~ "(none)"
      assert output =~ "Inherited from global:"
      assert output =~ "shell_cmd#git push: ✓ approved"
    end
  end

  describe "approvals approve" do
    test "approves global command when no project specified" do
      output =
        capture_io(fn ->
          Cmd.Config.run([command: "git push"], [:approvals, :approve], [])
        end)

      assert output =~ "Command 'git push' approved globally with tag 'shell_cmd'."

      # Verify it was actually set
      settings = Settings.new()
      approved_commands = Settings.get_approved_commands(settings, :global)
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      assert "git push" in shell_commands
    end

    test "approves project command when project specified" do
      project = mock_project("config_test_project")

      output =
        capture_io(fn ->
          Cmd.Config.run(
            [project: project.name, command: "make build"],
            [:approvals, :approve],
            []
          )
        end)

      assert output =~
               "Command 'make build' approved for project 'config_test_project' with tag 'shell_cmd'."

      # Verify it was actually set
      settings = Settings.new()
      approved_commands = Settings.get_approved_commands(settings, project.name)
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      assert "make build" in shell_commands
    end
  end

  describe "approvals deny" do
    test "shows error message that deny was removed" do
      output =
        capture_log(fn ->
          Cmd.Config.run([command: "rm -rf"], [:approvals, :deny], [])
        end)

      assert output =~
               "Deny functionality has been removed. Use 'remove' to remove approved commands."
    end

    test "shows error message for project deny as well" do
      project = mock_project("config_test_project")

      output =
        capture_log(fn ->
          Cmd.Config.run([project: project.name, command: "docker run"], [:approvals, :deny], [])
        end)

      assert output =~
               "Deny functionality has been removed. Use 'remove' to remove approved commands."
    end
  end

  describe "approvals remove" do
    test "removes global command when no project specified" do
      settings = Settings.new()
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")
      _settings = Settings.add_approved_command(settings, :global, "shell_cmd", "rm -rf")

      output =
        capture_io(fn ->
          Cmd.Config.run([command: "git push"], [:approvals, :remove], [])
        end)

      assert output =~ "Command 'git push' removed from global approval list for tag 'shell_cmd'."

      # Verify it was actually removed
      updated_settings = Settings.new()
      approved_commands = Settings.get_approved_commands(updated_settings, :global)
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      refute "git push" in shell_commands
      assert "rm -rf" in shell_commands
    end

    test "removes project command when project specified" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      settings = Settings.add_approved_command(settings, project.name, "shell_cmd", "make build")
      _settings = Settings.add_approved_command(settings, project.name, "shell_cmd", "docker run")

      output =
        capture_io(fn ->
          Cmd.Config.run(
            [project: project.name, command: "make build"],
            [:approvals, :remove],
            []
          )
        end)

      assert output =~
               "Command 'make build' removed from project 'config_test_project' approval list for tag 'shell_cmd'."

      # Verify it was actually removed
      updated_settings = Settings.new()

      approved_commands = Settings.get_approved_commands(updated_settings, project.name)
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      refute "make build" in shell_commands
      assert "docker run" in shell_commands
    end
  end

  describe "error handling" do
    test "unknown subcommand shows error" do
      log =
        capture_log(fn ->
          Cmd.Config.run([], ["unknown"], [])
        end)

      assert log =~ "Unknown subcommand"
    end

    test "no subcommand shows error" do
      log =
        capture_log(fn ->
          Cmd.Config.run([], [], [])
        end)

      assert log =~ "No subcommand specified"
    end
  end
end
