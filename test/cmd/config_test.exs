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
      settings = Settings.set_command_approval(settings, :global, "git push", true)
      _settings = Settings.set_command_approval(settings, :global, "rm -rf", false)

      output =
        capture_io(fn ->
          Cmd.Config.run([], [:list], [])
        end)

      decoded = Jason.decode!(output)
      approved_commands = decoded["approved_commands"]
      assert approved_commands["git push"] == true
      assert approved_commands["rm -rf"] == false
    end

    test "lists project configuration when project specified" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      _settings = Settings.set_command_approval(settings, project.name, "make build", true)

      output =
        capture_io(fn ->
          Cmd.Config.run([project: project.name], [:list], [])
        end)

      decoded = Jason.decode!(output)
      assert Map.get(decoded, "approved_commands") == %{"make build" => true}
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

  describe "approved-commands list" do
    test "shows global approved commands when no project specified" do
      settings = Settings.new()
      settings = Settings.set_command_approval(settings, :global, "git push", true)
      _settings = Settings.set_command_approval(settings, :global, "rm -rf", false)

      output =
        capture_io(fn ->
          Cmd.Config.run([], ["approved-commands", "list"], [])
        end)

      assert output =~ "Global approved commands:"
      # Check that both commands appear, regardless of order
      assert output =~ "git push"
      assert output =~ "rm -rf"
      assert output =~ "✓ approved"
      assert output =~ "✗ denied"
    end

    test "shows empty global commands" do
      _settings = Settings.new()

      output =
        capture_io(fn ->
          Cmd.Config.run([], ["approved-commands", "list"], [])
        end)

      assert output =~ "Global approved commands:"
      assert output =~ "(none)"
    end

    test "shows project approved commands with inheritance" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      settings = Settings.set_command_approval(settings, :global, "git push", true)
      settings = Settings.set_command_approval(settings, :global, "rm -rf", false)
      settings = Settings.set_command_approval(settings, project.name, "git push", false)
      _settings = Settings.set_command_approval(settings, project.name, "make build", true)

      output =
        capture_io(fn ->
          Cmd.Config.run([project: project.name], ["approved-commands", "list"], [])
        end)

      assert output =~ "Project 'config_test_project' approved commands:"
      assert output =~ "make build: ✓ approved"
      # The order of git push might vary - let's be more flexible
      assert output =~ "git push"
      assert output =~ "✗ denied"
      assert output =~ "Inherited from global:"
      assert output =~ "rm -rf: ✗ denied"
    end

    test "shows project commands with empty project list" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      _settings = Settings.set_command_approval(settings, :global, "git push", true)

      output =
        capture_io(fn ->
          Cmd.Config.run([project: project.name], ["approved-commands", "list"], [])
        end)

      assert output =~ "Project 'config_test_project' approved commands:"
      assert output =~ "(none)"
      assert output =~ "Inherited from global:"
      assert output =~ "git push: ✓ approved"
    end
  end

  describe "approved-commands approve" do
    test "approves global command when no project specified" do
      output =
        capture_io(fn ->
          Cmd.Config.run([], ["approved-commands", "approve", "git push"], [])
        end)

      assert output =~ "Command 'git push' approved globally."

      # Verify it was actually set
      settings = Settings.new()
      assert Settings.get_approved_commands(settings, :global) == %{"git push" => true}
    end

    test "approves project command when project specified" do
      project = mock_project("config_test_project")

      output =
        capture_io(fn ->
          Cmd.Config.run(
            [project: project.name],
            ["approved-commands", "approve", "make build"],
            []
          )
        end)

      assert output =~ "Command 'make build' approved for project 'config_test_project'."

      # Verify it was actually set
      settings = Settings.new()
      assert Settings.get_approved_commands(settings, project.name) == %{"make build" => true}
    end
  end

  describe "approved-commands deny" do
    test "denies global command when no project specified" do
      output =
        capture_io(fn ->
          Cmd.Config.run([], ["approved-commands", "deny", "rm -rf"], [])
        end)

      assert output =~ "Command 'rm -rf' denied globally."

      # Verify it was actually set
      settings = Settings.new()
      assert Settings.get_approved_commands(settings, :global) == %{"rm -rf" => false}
    end

    test "denies project command when project specified" do
      project = mock_project("config_test_project")

      output =
        capture_io(fn ->
          Cmd.Config.run([project: project.name], ["approved-commands", "deny", "docker run"], [])
        end)

      assert output =~ "Command 'docker run' denied for project 'config_test_project'."

      # Verify it was actually set
      settings = Settings.new()
      assert Settings.get_approved_commands(settings, project.name) == %{"docker run" => false}
    end
  end

  describe "approved-commands remove" do
    test "removes global command when no project specified" do
      settings = Settings.new()
      settings = Settings.set_command_approval(settings, :global, "git push", true)
      _settings = Settings.set_command_approval(settings, :global, "rm -rf", false)

      output =
        capture_io(fn ->
          Cmd.Config.run([], ["approved-commands", "remove", "git push"], [])
        end)

      assert output =~ "Command 'git push' removed from global approval list."

      # Verify it was actually removed
      updated_settings = Settings.new()
      assert Settings.get_approved_commands(updated_settings, :global) == %{"rm -rf" => false}
    end

    test "removes project command when project specified" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      settings = Settings.set_command_approval(settings, project.name, "make build", true)
      _settings = Settings.set_command_approval(settings, project.name, "docker run", false)

      output =
        capture_io(fn ->
          Cmd.Config.run(
            [project: project.name],
            ["approved-commands", "remove", "make build"],
            []
          )
        end)

      assert output =~ "Command 'make build' removed from project 'config_test_project' approval list."

      # Verify it was actually removed
      updated_settings = Settings.new()

      assert Settings.get_approved_commands(updated_settings, project.name) == %{
               "docker run" => false
             }
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
