defmodule SettingsTest do
  use Fnord.TestCase

  describe "project" do
    test "project_is_set?/0 returns false when project is not set and true when set" do
      set_config(:project, nil)
      refute Settings.project_is_set?()

      set_config(:project, "my_project")
      assert Settings.project_is_set?()
    end

    test "get_selected_project/0 returns error when project not set and ok when set" do
      set_config(:project, nil)
      assert Settings.get_selected_project() == {:error, :project_not_set}

      set_config(:project, "my_project")
      assert Settings.get_selected_project() == {:ok, "my_project"}
    end
  end

  test "home/0", %{home_dir: home_dir} do
    assert Settings.home() == Path.join(home_dir, ".fnord")
  end

  test "settings_file/0", %{home_dir: home_dir} do
    assert Settings.settings_file() == Path.join(home_dir, ".fnord/settings.json")
  end

  test "get/3 <-> set/3" do
    settings = Settings.new()

    assert Settings.get(settings, "foo", "bar") == "bar"

    settings = Settings.set(settings, "foo", "baz")
    assert Settings.get(settings, "foo", "bar") == "baz"
  end

  test "delete/2" do
    settings = Settings.new()

    settings = Settings.set(settings, "foo", "baz")
    assert Settings.get(settings, "foo", "bar") == "baz"

    settings = Settings.delete(settings, "foo")
    assert Settings.get(settings, "foo", :deleted) == :deleted
  end

  test "automatic cleanup of default project directory" do
    home = Settings.home()
    default_dir = Path.join(home, "default")

    # Setup: ensure the default dir exists
    File.mkdir_p!(default_dir)
    assert File.exists?(default_dir)

    # Call Settings.new() which triggers cleanup
    _settings = Settings.new()

    # Assert directory no longer exists
    refute File.exists?(default_dir)

    # Cleanup (in case)
    File.rm_rf!(default_dir)
  end

  describe "approved_commands" do
    test "migration adds approved_commands to global and project configs on spew" do
      settings = Settings.new()

      # Add a project without approved_commands
      _settings =
        Settings.set(settings, "settings_test_project", %{"root" => "/test", "exclude" => []})

      # Verify migration added approved_commands
      updated_settings = Settings.new()
      assert Settings.get(updated_settings, "approved_commands", :missing) == %{}

      project_data = Settings.get(updated_settings, "settings_test_project")
      assert Map.get(project_data, "approved_commands") == %{}
    end

    test "get_approved_commands/2 returns empty map for global when not set" do
      settings = Settings.new()
      assert Settings.get_approved_commands(settings, :global) == %{}
    end

    test "get_approved_commands/2 returns empty map for project when not set" do
      settings = Settings.new()
      assert Settings.get_approved_commands(settings, "nonexistent") == %{}
    end

    test "get_approved_commands/2 returns existing commands" do
      settings = Settings.new()
      commands = %{"git push" => true, "rm -rf" => false}
      settings = Settings.set(settings, "approved_commands", commands)

      assert Settings.get_approved_commands(settings, :global) == commands
    end

    test "add_approved_command/4 adds global command approval" do
      settings = Settings.new()

      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")
      approved_commands = Settings.get_approved_commands(settings, :global)
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      assert "git push" in shell_commands

      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "rm -rf")
      approved_commands = Settings.get_approved_commands(settings, :global)
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      assert "git push" in shell_commands
      assert "rm -rf" in shell_commands
    end

    test "add_approved_command/4 adds project command approval" do
      settings = Settings.new()
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})

      settings =
        Settings.add_approved_command(
          settings,
          "settings_test_project",
          "shell_cmd",
          "make build"
        )

      approved_commands = Settings.get_approved_commands(settings, "settings_test_project")
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      assert "make build" in shell_commands

      settings =
        Settings.add_approved_command(
          settings,
          "settings_test_project",
          "shell_cmd",
          "docker run"
        )

      approved_commands = Settings.get_approved_commands(settings, "settings_test_project")
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      assert "make build" in shell_commands
      assert "docker run" in shell_commands
    end

    test "remove_approved_command/4 removes global command" do
      settings = Settings.new()
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "rm -rf")

      settings = Settings.remove_approved_command(settings, :global, "shell_cmd", "git push")
      approved_commands = Settings.get_approved_commands(settings, :global)
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      refute "git push" in shell_commands
      assert "rm -rf" in shell_commands
    end

    test "remove_approved_command/4 removes project command" do
      settings = Settings.new()
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})

      settings =
        Settings.add_approved_command(
          settings,
          "settings_test_project",
          "shell_cmd",
          "make build"
        )

      settings =
        Settings.add_approved_command(
          settings,
          "settings_test_project",
          "shell_cmd",
          "docker run"
        )

      settings =
        Settings.remove_approved_command(
          settings,
          "settings_test_project",
          "shell_cmd",
          "make build"
        )

      approved_commands = Settings.get_approved_commands(settings, "settings_test_project")
      shell_commands = Map.get(approved_commands, "shell_cmd", [])
      refute "make build" in shell_commands
      assert "docker run" in shell_commands
    end

    test "is_command_approved?/4 checks project approval first" do
      settings = Settings.new()
      # Add to global but NOT to project to show project scope is checked first
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "other_command")
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})

      # Add command only to project
      settings =
        Settings.add_approved_command(settings, "settings_test_project", "shell_cmd", "git push")

      # Should find it in project scope
      assert Settings.is_command_approved?(
               settings,
               "settings_test_project",
               "shell_cmd",
               "git push"
             ) == true

      # Should not find other command in project scope
      assert Settings.is_command_approved?(
               settings,
               "settings_test_project",
               "shell_cmd",
               "other_command"
             ) == false
    end

    test "is_command_approved?/4 works with global scope" do
      settings = Settings.new()
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})

      # Should find global approval
      assert Settings.is_command_approved?(settings, :global, "shell_cmd", "git push") == true
      # Should not find non-existent command
      assert Settings.is_command_approved?(settings, :global, "shell_cmd", "unknown") == false
    end

    test "is_command_approved?/4 returns false when command not found" do
      settings = Settings.new()
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})

      # Should return false for non-existent commands
      assert Settings.is_command_approved?(
               settings,
               "settings_test_project",
               "shell_cmd",
               "unknown"
             ) == false

      assert Settings.is_command_approved?(settings, :global, "shell_cmd", "unknown") == false
    end

    test "is_command_approved?/4 works correctly with global scope only" do
      settings = Settings.new()
      settings = Settings.add_approved_command(settings, :global, "shell_cmd", "git push")

      # Should find global approval
      assert Settings.is_command_approved?(settings, :global, "shell_cmd", "git push") == true
      # Should not find non-existent command
      assert Settings.is_command_approved?(settings, :global, "shell_cmd", "unknown") == false
    end

    test "migration preserves existing approved_commands" do
      settings = Settings.new()
      existing_global = %{"existing" => true}
      existing_project = %{"root" => "/test", "approved_commands" => %{"project_cmd" => false}}

      settings = Settings.set(settings, "approved_commands", existing_global)
      settings = Settings.set(settings, "settings_test_project", existing_project)

      # Trigger another migration
      _settings = Settings.set(settings, "another_project", %{"root" => "/other"})

      # Verify existing data preserved
      updated_settings = Settings.new()
      assert Settings.get_approved_commands(updated_settings, :global) == existing_global

      assert Settings.get_approved_commands(updated_settings, "settings_test_project") == %{
               "project_cmd" => false
             }

      assert Settings.get_approved_commands(updated_settings, "another_project") == %{}
    end
  end
end
