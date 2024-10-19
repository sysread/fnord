defmodule SettingsTest do
  use ExUnit.Case

  # Set up a temporary directory and override the HOME environment variable
  setup do
    # Create a unique temporary directory
    tmp_dir = System.tmp_dir!() |> Path.join("store_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    # Save the original HOME environment variable
    original_home = System.get_env("HOME")

    # Override the HOME environment variable with the temporary directory
    System.put_env("HOME", tmp_dir)

    # Ensure the original HOME is restored and temporary directory is cleaned up after tests
    on_exit(fn ->
      # Restore the original HOME environment variable
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Remove the temporary directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "home/0", %{tmp_dir: tmp_dir} do
    assert Settings.home() == Path.join(tmp_dir, ".fnord")
  end

  test "settings_file/0", %{tmp_dir: tmp_dir} do
    assert Settings.settings_file() == Path.join(tmp_dir, ".fnord/settings.json")
  end

  test "get/3 <-> set/3", %{tmp_dir: tmp_dir} do
    settings = Settings.new()

    assert Settings.get(settings, "foo", "bar") == "bar"

    settings = Settings.set(settings, "foo", "baz")
    assert Settings.get(settings, "foo", "bar") == "baz"
  end
end
