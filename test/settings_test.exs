defmodule SettingsTest do
  use ExUnit.Case

  use TestUtil

  test "home/0", %{fnord_home: fnord_home} do
    assert Settings.home() == Path.join(fnord_home, ".fnord")
  end

  test "settings_file/0", %{fnord_home: fnord_home} do
    assert Settings.settings_file() == Path.join(fnord_home, ".fnord/settings.json")
  end

  test "get/3 <-> set/3" do
    settings = Settings.new()

    assert Settings.get(settings, "foo", "bar") == "bar"

    settings = Settings.set(settings, "foo", "baz")
    assert Settings.get(settings, "foo", "bar") == "baz"
  end
end
