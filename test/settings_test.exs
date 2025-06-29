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
end
