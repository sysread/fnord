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

      project_data = Settings.get_project_data(updated_settings, "settings_test_project")
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

  describe "settings migration" do
    setup do
      # Override version for testing migration logic
      Application.put_env(:fnord, :test_version_override, "0.8.30")

      on_exit(fn ->
        Application.delete_env(:fnord, :test_version_override)
      end)
    end

    test "migrates old format to new nested format", %{home_dir: home_dir} do
      settings_path = Path.join(home_dir, ".fnord/settings.json")
      File.mkdir_p!(Path.dirname(settings_path))

      # Create old format settings
      old_settings = %{
        "approved_commands" => %{"shell_cmd" => ["git status"]},
        "my_project" => %{
          "root" => "/test/project",
          "approved_commands" => %{"project_cmd" => ["make build"]}
        },
        "another_project" => %{
          "root" => "/another/path",
          "exclude" => ["node_modules"]
        }
      }

      File.write!(settings_path, Jason.encode!(old_settings, pretty: true))

      # Load settings - this should trigger migration
      settings = Settings.new()

      # Verify migration happened
      assert Settings.get(settings, "version") == "0.8.30"
      assert Settings.get(settings, "approved_commands") == %{"shell_cmd" => ["git status"]}

      projects = Settings.get(settings, "projects")
      assert Map.has_key?(projects, "my_project")
      assert Map.has_key?(projects, "another_project")

      assert projects["my_project"]["root"] == "/test/project"
      assert projects["my_project"]["approved_commands"] == %{"project_cmd" => ["make build"]}
      assert projects["another_project"]["root"] == "/another/path"
      assert projects["another_project"]["exclude"] == ["node_modules"]

      # Verify old format keys are gone from root level
      refute Map.has_key?(settings.data, "my_project")
      refute Map.has_key?(settings.data, "another_project")
    end

    test "skips migration when already migrated", %{home_dir: home_dir} do
      settings_path = Path.join(home_dir, ".fnord/settings.json")
      File.mkdir_p!(Path.dirname(settings_path))

      # Create already-migrated settings
      migrated_settings = %{
        "approved_commands" => %{"shell_cmd" => ["git status"]},
        "version" => "0.8.30",
        "projects" => %{
          "my_project" => %{
            "root" => "/test/project",
            "approved_commands" => %{"project_cmd" => ["make build"]}
          }
        }
      }

      File.write!(settings_path, Jason.encode!(migrated_settings, pretty: true))

      # Load settings - should not modify anything
      settings = Settings.new()

      # Verify settings unchanged
      assert Settings.get(settings, "version") == "0.8.30"
      assert Settings.get(settings, "approved_commands") == %{"shell_cmd" => ["git status"]}

      projects = Settings.get(settings, "projects")
      assert projects["my_project"]["root"] == "/test/project"
      assert projects["my_project"]["approved_commands"] == %{"project_cmd" => ["make build"]}
    end

    test "migration handles empty settings file", %{home_dir: home_dir} do
      settings_path = Path.join(home_dir, ".fnord/settings.json")
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(settings_path, "{}")

      # Load settings - should add version and projects
      settings = Settings.new()

      assert Settings.get(settings, "version") == "0.8.30"
      assert Settings.get(settings, "projects") == %{}
      # ensure_approved_commands_exist adds this if not present
      assert Settings.get(settings, "approved_commands") == %{}
    end

    test "migration preserves approved_commands without projects", %{home_dir: home_dir} do
      settings_path = Path.join(home_dir, ".fnord/settings.json")
      File.mkdir_p!(Path.dirname(settings_path))

      # Create settings with only global approved_commands
      old_settings = %{
        "approved_commands" => %{"shell_cmd" => ["git push", "rm -rf"]}
      }

      File.write!(settings_path, Jason.encode!(old_settings, pretty: true))

      settings = Settings.new()

      assert Settings.get(settings, "version") == "0.8.30"

      assert Settings.get(settings, "approved_commands") == %{
               "shell_cmd" => ["git push", "rm -rf"]
             }

      assert Settings.get(settings, "projects") == %{}
    end

    test "migration is skipped when version is below threshold", %{home_dir: home_dir} do
      # Override version to be below migration threshold
      Application.put_env(:fnord, :test_version_override, "0.8.29")

      settings_path = Path.join(home_dir, ".fnord/settings.json")
      File.mkdir_p!(Path.dirname(settings_path))

      # Create old format settings
      old_settings = %{
        "approved_commands" => %{"shell_cmd" => ["git status"]},
        "my_project" => %{
          "root" => "/test/project"
        }
      }

      File.write!(settings_path, Jason.encode!(old_settings, pretty: true))

      # Load settings - migration should be skipped
      settings = Settings.new()

      # Verify migration did NOT happen (no version or projects key added)
      assert Settings.get(settings, "version", :not_found) == :not_found
      assert Settings.get(settings, "projects", :not_found) == :not_found

      # Old format should still be accessible
      assert Settings.get(settings, "my_project") != nil

      # Clean up the override
      Application.delete_env(:fnord, :test_version_override)
    end

    test "migration is skipped with current production version (0.8.28)", %{home_dir: home_dir} do
      # Don't set any version override - use actual production version
      settings_path = Path.join(home_dir, ".fnord/settings.json")
      File.mkdir_p!(Path.dirname(settings_path))

      # Create old format settings
      old_settings = %{
        "approved_commands" => %{"shell_cmd" => ["git status"]},
        "my_project" => %{
          "root" => "/test/project"
        }
      }

      File.write!(settings_path, Jason.encode!(old_settings, pretty: true))

      # Remove any test version override to use production version (0.8.28)
      Application.delete_env(:fnord, :test_version_override)

      # Load settings - migration should be skipped with 0.8.28
      settings = Settings.new()

      # Verify migration did NOT happen (no version or projects key added)
      assert Settings.get(settings, "version", :not_found) == :not_found
      assert Settings.get(settings, "projects", :not_found) == :not_found

      # Old format should still be accessible
      assert Settings.get(settings, "my_project") != nil
    end
  end

  describe "project data access with new format" do
    test "get_project_data works with new nested format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}

      settings = Settings.set_project_data(settings, "test_project", project_data)

      # The ensure_approved_commands_exist function adds approved_commands
      expected_data = Map.put(project_data, "approved_commands", %{})
      assert Settings.get_project_data(settings, "test_project") == expected_data
      projects = Settings.get(settings, "projects")
      assert Map.get(projects, "test_project") == expected_data
    end

    test "get_project_data falls back to old format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}

      # Set in old format directly
      settings = Settings.set(settings, "old_project", project_data)

      # The ensure_approved_commands_exist function adds approved_commands
      expected_data = Map.put(project_data, "approved_commands", %{})
      assert Settings.get_project_data(settings, "old_project") == expected_data
    end

    test "set_project_data uses new nested format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}

      updated_settings = Settings.set_project_data(settings, "new_project", project_data)

      projects = Settings.get(updated_settings, "projects")
      # The ensure_approved_commands_exist function adds approved_commands
      expected_data = Map.put(project_data, "approved_commands", %{})
      assert Map.get(projects, "new_project") == expected_data
      # Should not be at root level
      assert Settings.get(updated_settings, "new_project", :not_found) == :not_found
    end

    test "delete_project_data removes from both old and new format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}

      # Add project in new format
      settings = Settings.set_project_data(settings, "test_project", project_data)
      # Also add in old format for testing cleanup
      settings = Settings.set(settings, "old_format_project", project_data)

      # Verify projects exist
      assert Settings.get_project_data(settings, "test_project") != nil
      assert Settings.get(settings, "old_format_project") != nil

      # Delete from new format
      settings = Settings.delete_project_data(settings, "test_project")
      assert Settings.get_project_data(settings, "test_project") == nil

      # Delete from old format
      settings = Settings.delete_project_data(settings, "old_format_project")
      assert Settings.get(settings, "old_format_project", :not_found) == :not_found
    end
  end
end
