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
      settings = Settings.add_approval(settings, :global, "shell_cmd", "git push")
      _settings = Settings.add_approval(settings, :global, "shell_cmd", "rm -rf")

      output =
        capture_io(fn ->
          Cmd.Config.run([], [:list], [])
        end)

      decoded = Jason.decode!(output)
      approvals = decoded["approvals"]
      shell_commands = Map.get(approvals, "shell_cmd", [])
      assert "git push" in shell_commands
      assert "rm -rf" in shell_commands
    end

    test "lists project configuration when project specified" do
      project = mock_project("config_test_project")

      settings = Settings.new()
      _settings = Settings.add_approval(settings, project.name, "shell_cmd", "make build")

      output =
        capture_io(fn ->
          Cmd.Config.run([project: project.name], [:list], [])
        end)

      decoded = Jason.decode!(output)
      approvals = Map.get(decoded, "approvals", %{})
      shell_commands = Map.get(approvals, "shell_cmd", [])
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
