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

  describe "approvals" do
    test "migration adds approvals to global and project configs on spew" do
      settings = Settings.new()

      # Add a project without approvals
      _settings =
        Settings.set(settings, "settings_test_project", %{"root" => "/test", "exclude" => []})

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
      settings = Settings.set(settings, "old_project", project_data)

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
