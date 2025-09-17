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

  test "get/3 <-> update/4" do
    settings = Settings.new()

    assert Settings.get(settings, "foo", "bar") == "bar"

    settings = Settings.update(settings, "foo", fn _ -> "baz" end)
    assert Settings.get(settings, "foo", "bar") == "baz"
  end

  test "update/4 uses current value in updater function" do
    settings = Settings.new()

    # Set initial value
    settings = Settings.update(settings, "count", fn _ -> 5 end)
    assert Settings.get(settings, "count") == 5

    # Update using current value
    settings = Settings.update(settings, "count", fn current -> current + 10 end)
    assert Settings.get(settings, "count") == 15

    # Update again using current value
    settings = Settings.update(settings, "count", fn current -> current * 2 end)
    assert Settings.get(settings, "count") == 30
  end

  test "update/4 uses default when key doesn't exist" do
    settings = Settings.new()

    # Update non-existent key with custom default
    settings = Settings.update(settings, "missing", fn current -> current + 1 end, 100)
    assert Settings.get(settings, "missing") == 101

    # Update non-existent key with default default (%{})
    settings = Settings.update(settings, "map_key", fn current -> Map.put(current, "nested", "value") end)
    assert Settings.get(settings, "map_key") == %{"nested" => "value"}
  end

  test "update/4 handles map manipulation" do
    settings = Settings.new()

    # Start with empty map
    settings = Settings.update(settings, "config", fn current -> Map.put(current, "enabled", true) end)
    assert Settings.get(settings, "config") == %{"enabled" => true}

    # Add more keys
    settings = Settings.update(settings, "config", fn current ->
      current
      |> Map.put("timeout", 30)
      |> Map.put("retries", 3)
    end)

    expected = %{"enabled" => true, "timeout" => 30, "retries" => 3}
    assert Settings.get(settings, "config") == expected
  end

  test "update/4 handles :delete return value" do
    settings = Settings.new()

    settings = Settings.update(settings, "foo", fn _ -> "baz" end)
    assert Settings.get(settings, "foo", "bar") == "baz"

    settings = Settings.update(settings, "foo", fn _ -> :delete end)
    assert Settings.get(settings, "foo", :deleted) == :deleted
  end

  test "update/4 can conditionally delete based on current value" do
    settings = Settings.new()

    # Set up some values
    settings = Settings.update(settings, "enabled", fn _ -> true end)
    settings = Settings.update(settings, "disabled", fn _ -> false end)
    settings = Settings.update(settings, "count", fn _ -> 0 end)

    # Conditionally delete based on current values
    settings = Settings.update(settings, "enabled", fn
      true -> :delete
      other -> other
    end)

    settings = Settings.update(settings, "disabled", fn
      false -> "was_false"
      other -> other
    end)

    settings = Settings.update(settings, "count", fn
      0 -> :delete
      other -> other + 1
    end)

    # Verify results
    assert Settings.get(settings, "enabled", :missing) == :missing
    assert Settings.get(settings, "disabled") == "was_false"
    assert Settings.get(settings, "count", :missing) == :missing
  end

  test "update/4 delete works with missing keys" do
    settings = Settings.new()

    # Try to delete a key that doesn't exist - should not cause issues
    settings = Settings.update(settings, "nonexistent", fn _current -> :delete end)

    # Verify it's still missing
    assert Settings.get(settings, "nonexistent", :still_missing) == :still_missing
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

  describe "approvals" do
    test "migration adds approvals to global and project configs on spew" do
      settings = Settings.new()

      # Add a project without approvals
      _settings =
        Settings.update(settings, "settings_test_project", fn _ -> %{"root" => "/test", "exclude" => []} end)

      # Verify migration added approvals
      updated_settings = Settings.new()
      assert Settings.get(updated_settings, "approvals", :missing) == %{}

      project_data = Settings.get_project_data(updated_settings, "settings_test_project")
      assert Map.get(project_data, "approvals") == %{}
    end
  end

  describe "project data access with new format" do
    test "get_project_data works with new nested format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}
      settings = Settings.set_project_data(settings, "test_project", project_data)

      expected =
        project_data
        |> Map.put("approvals", %{})
        |> Map.put("name", "test_project")

      actual = Settings.get_project_data(settings, "test_project")
      assert actual == expected

      projects = Settings.get(settings, "projects")
      expected = Map.put(project_data, "approvals", %{})
      assert Map.get(projects, "test_project") == expected
    end

    test "get_project_data falls back to old format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}
      settings = Settings.update(settings, "old_project", fn _ -> project_data end)

      expected_data =
        project_data
        |> Map.put("approvals", %{})
        |> Map.put("name", "old_project")

      assert Settings.get_project_data(settings, "old_project") == expected_data
    end

    test "set_project_data uses new nested format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}

      updated_settings = Settings.set_project_data(settings, "new_project", project_data)

      projects = Settings.get(updated_settings, "projects")
      # The ensure_approvals_exist function adds approvals
      expected_data = Map.put(project_data, "approvals", %{})
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
      settings = Settings.update(settings, "old_format_project", fn _ -> project_data end)

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
