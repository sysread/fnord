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
      _settings = Settings.set(settings, "settings_test_project", %{"root" => "/test", "exclude" => []})

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

    test "set_command_approval/4 sets global command approval" do
      settings = Settings.new()

      settings = Settings.set_command_approval(settings, :global, "git push", true)
      assert Settings.get_approved_commands(settings, :global) == %{"git push" => true}

      settings = Settings.set_command_approval(settings, :global, "rm -rf", false)
      expected = %{"git push" => true, "rm -rf" => false}
      assert Settings.get_approved_commands(settings, :global) == expected
    end

    test "set_command_approval/4 sets project command approval" do
      settings = Settings.new()
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})

      settings = Settings.set_command_approval(settings, "settings_test_project", "make build", true)
      assert Settings.get_approved_commands(settings, "settings_test_project") == %{"make build" => true}

      settings = Settings.set_command_approval(settings, "settings_test_project", "docker run", false)
      expected = %{"make build" => true, "docker run" => false}
      assert Settings.get_approved_commands(settings, "settings_test_project") == expected
    end

    test "remove_command_approval/3 removes global command" do
      settings = Settings.new()
      settings = Settings.set_command_approval(settings, :global, "git push", true)
      settings = Settings.set_command_approval(settings, :global, "rm -rf", false)

      settings = Settings.remove_command_approval(settings, :global, "git push")
      assert Settings.get_approved_commands(settings, :global) == %{"rm -rf" => false}
    end

    test "remove_command_approval/3 removes project command" do
      settings = Settings.new()
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})
      settings = Settings.set_command_approval(settings, "settings_test_project", "make build", true)
      settings = Settings.set_command_approval(settings, "settings_test_project", "docker run", false)

      settings = Settings.remove_command_approval(settings, "settings_test_project", "make build")
      assert Settings.get_approved_commands(settings, "settings_test_project") == %{"docker run" => false}
    end

    test "get_command_approval/3 returns project approval over global" do
      settings = Settings.new()
      settings = Settings.set_command_approval(settings, :global, "git push", false)
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})
      settings = Settings.set_command_approval(settings, "settings_test_project", "git push", true)

      assert Settings.get_command_approval(settings, "settings_test_project", "git push") == {:ok, true}
    end

    test "get_command_approval/3 falls back to global when not set in project" do
      settings = Settings.new()
      settings = Settings.set_command_approval(settings, :global, "git push", true)
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})

      assert Settings.get_command_approval(settings, "settings_test_project", "git push") == {:ok, true}
    end

    test "get_command_approval/3 returns error when command not found anywhere" do
      settings = Settings.new()
      settings = Settings.set(settings, "settings_test_project", %{"root" => "/test"})

      assert Settings.get_command_approval(settings, "settings_test_project", "unknown") ==
               {:error, :not_found}
    end

    test "get_global_command_approval/2 returns global approval only" do
      settings = Settings.new()
      settings = Settings.set_command_approval(settings, :global, "git push", true)

      assert Settings.get_global_command_approval(settings, "git push") == {:ok, true}
    end

    test "get_global_command_approval/2 returns error when not found" do
      settings = Settings.new()

      assert Settings.get_global_command_approval(settings, "unknown") == {:error, :not_found}
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
