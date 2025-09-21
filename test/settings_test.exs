defmodule SettingsTest do
  use Fnord.TestCase, async: false

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
    assert Settings.fnord_home() == Path.join(home_dir, ".fnord")
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
    settings =
      Settings.update(settings, "map_key", fn current -> Map.put(current, "nested", "value") end)

    assert Settings.get(settings, "map_key") == %{"nested" => "value"}
  end

  test "update/4 handles map manipulation" do
    settings = Settings.new()

    # Start with empty map
    settings =
      Settings.update(settings, "config", fn current -> Map.put(current, "enabled", true) end)

    assert Settings.get(settings, "config") == %{"enabled" => true}

    # Add more keys
    settings =
      Settings.update(settings, "config", fn current ->
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
    settings =
      Settings.update(settings, "enabled", fn
        true -> :delete
        other -> other
      end)

    settings =
      Settings.update(settings, "disabled", fn
        false -> "was_false"
        other -> other
      end)

    settings =
      Settings.update(settings, "count", fn
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

  test "concurrent updates to same key don't lose data", %{home_dir: _} do
    # This tests the critical case where multiple processes update the same key
    # and we need to ensure no data is lost due to read-modify-write races
    key = "concurrent_counter"
    num_tasks = 10
    increments_per_task = 5

    # Initialize counter
    Settings.new() |> Settings.update(key, fn _ -> 0 end)

    tasks =
      for _i <- 1..num_tasks do
        Services.Globals.Spawn.async(fn ->
          for _j <- 1..increments_per_task do
            Settings.new()
            |> Settings.update(key, fn current ->
              # Simulate some work and ensure we use the current value
              :timer.sleep(1)
              current + 1
            end)
          end
        end)
      end

    # Wait for all tasks to complete
    Enum.each(tasks, &Task.await(&1, 30_000))

    # Verify final count is correct
    final_count = Settings.new() |> Settings.get(key)
    expected = num_tasks * increments_per_task

    assert final_count == expected,
           "Expected #{expected} but got #{final_count} - lost #{expected - final_count} updates"
  end

  test "concurrent updates to different keys don't interfere", %{home_dir: _} do
    # Test that updates to different keys don't cause data corruption
    num_tasks = 8
    updates_per_task = 10

    tasks =
      for i <- 1..num_tasks do
        Services.Globals.Spawn.async(fn ->
          key = "task_#{i}"

          for j <- 1..updates_per_task do
            Settings.new()
            |> Settings.update(key, fn _ -> "task_#{i}_value_#{j}" end)
          end
        end)
      end

    # Wait for completion
    Enum.each(tasks, &Task.await(&1, 30_000))

    # Verify all keys have their expected final values
    settings = Settings.new()

    for i <- 1..num_tasks do
      key = "task_#{i}"
      expected = "task_#{i}_value_#{updates_per_task}"
      actual = Settings.get(settings, key)
      assert actual == expected, "Task #{i}: expected '#{expected}' but got '#{actual}'"
    end
  end

  test "concurrent deletes and updates don't corrupt settings", %{home_dir: _} do
    # Test mixed operations that could cause corruption
    settings = Settings.new()

    # Pre-populate some data
    initial_data = for i <- 1..20, into: %{}, do: {"key_#{i}", "initial_value_#{i}"}

    _settings =
      Enum.reduce(initial_data, settings, fn {key, value}, acc ->
        Settings.update(acc, key, fn _ -> value end)
      end)

    num_tasks = 10

    tasks =
      for i <- 1..num_tasks do
        Services.Globals.Spawn.async(fn ->
          for j <- 1..5 do
            key = "key_#{rem(i * j, 20) + 1}"

            case rem(i + j, 3) do
              0 ->
                # Delete the key
                Settings.new() |> Settings.update(key, fn _ -> :delete end)

              1 ->
                # Update with new value
                Settings.new() |> Settings.update(key, fn _ -> "updated_by_task_#{i}_#{j}" end)

              2 ->
                # Conditional update based on current value
                Settings.new()
                |> Settings.update(key, fn
                  current when is_binary(current) -> current <> "_modified"
                  _ -> "recreated_by_task_#{i}_#{j}"
                end)
            end
          end
        end)
      end

    Enum.each(tasks, &Task.await(&1, 30_000))

    # Verify settings file is still valid JSON and not corrupted
    final_settings = Settings.new()
    assert is_struct(final_settings, Settings)
    assert is_map(final_settings.data)

    # Verify we can still read and write
    test_key = "post_test_verification"
    result = Settings.update(final_settings, test_key, fn _ -> "success" end)
    assert Settings.get(result, test_key) == "success"
  end

  test "settings file corruption recovery", %{home_dir: _home_dir} do
    # Test what happens if the settings file gets corrupted during concurrent access
    settings_file = Settings.settings_file()

    # Create initial valid settings
    Settings.new() |> Settings.update("test_key", fn _ -> "test_value" end)

    # Simulate file corruption by writing invalid JSON
    File.write!(settings_file, "{invalid json")

    # Attempting to read should raise with a helpful error
    assert_raise RuntimeError, ~r/Corrupted settings file/, fn ->
      Settings.new()
    end

    # Cleanup - restore valid JSON for other tests
    File.write!(settings_file, "{}")
  end

  test "approval operations don't wipe existing approvals", %{home_dir: _} do
    # This specifically tests the bug where adding one approval wipes out others
    settings = Settings.new()

    # Set up multiple existing approvals
    settings =
      Settings.update(settings, "approvals", fn _ ->
        %{
          "shell" => ["existing_approval_1", "existing_approval_2"],
          "shell_full" => [".*\\.txt"],
          "other_category" => ["keep_this"]
        }
      end)

    # Verify they exist
    approvals = Settings.get(settings, "approvals")
    assert length(approvals["shell"]) == 2
    assert length(approvals["shell_full"]) == 1
    assert length(approvals["other_category"]) == 1

    # Now simulate what happens during an approval operation
    # (this mimics what the Approvals module might do)
    settings =
      Settings.update(settings, "approvals", fn current_approvals ->
        # Add a new approval to shell category
        updated_shell = (current_approvals["shell"] || []) ++ ["new_approval"]
        Map.put(current_approvals, "shell", updated_shell)
      end)

    # Verify the other categories weren't wiped out
    final_approvals = Settings.get(settings, "approvals")
    assert length(final_approvals["shell"]) == 3
    assert final_approvals["shell_full"] == [".*\\.txt"], "shell_full approvals were lost!"

    assert final_approvals["other_category"] == ["keep_this"],
           "other_category approvals were lost!"
  end

  test "concurrent approval additions don't lose existing approvals", %{home_dir: _} do
    # Test the specific scenario: two worktrees adding approvals concurrently
    settings = Settings.new()

    # Set up existing approvals like a real user would have
    _settings =
      Settings.update(settings, "approvals", fn _ ->
        %{
          "shell" => ["git status", "git diff", "make test"],
          "shell_full" => ["find . -name '*.ex'", "grep -r 'TODO'"],
          "edit" => ["/project/src/**/*.ex"]
        }
      end)

    # Simulate two different worktrees/processes adding approvals simultaneously
    tasks = [
      Services.Globals.Spawn.async(fn ->
        # Process 1: Add approval to shell
        Settings.new()
        |> Settings.update("approvals", fn approvals ->
          shell_approvals = Map.get(approvals, "shell", []) ++ ["git log"]
          Map.put(approvals, "shell", shell_approvals)
        end)
      end),
      Services.Globals.Spawn.async(fn ->
        # Process 2: Add approval to shell_full
        Settings.new()
        |> Settings.update("approvals", fn approvals ->
          shell_full_approvals = Map.get(approvals, "shell_full", []) ++ ["rg 'pattern' ."]
          Map.put(approvals, "shell_full", shell_full_approvals)
        end)
      end)
    ]

    Enum.each(tasks, &Task.await(&1, 15_000))

    # Check final state - both new approvals should exist AND old ones preserved
    final_approvals = Settings.get(Settings.new(), "approvals")

    # Should have at least the original approvals plus new ones
    shell_count = length(final_approvals["shell"] || [])
    shell_full_count = length(final_approvals["shell_full"] || [])
    edit_count = length(final_approvals["edit"] || [])

    assert shell_count >= 3, "Shell approvals missing: #{inspect(final_approvals["shell"])}"

    assert shell_full_count >= 2,
           "Shell_full approvals missing: #{inspect(final_approvals["shell_full"])}"

    assert edit_count >= 1, "Edit approvals missing: #{inspect(final_approvals["edit"])}"

    # Make sure specific approvals exist
    assert "git status" in final_approvals["shell"], "Original shell approval lost"
    assert "/project/src/**/*.ex" in final_approvals["edit"], "Original edit approval lost"
  end

  test "automatic cleanup of default project directory" do
    home = Settings.fnord_home()
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
    test "approvals read functions handle completely missing approvals key" do
      # Create settings with NO approvals key at all
      settings_file = Settings.settings_file()

      File.write!(
        settings_file,
        Jason.encode!(%{
          "some_other_key" => "value",
          "projects" => %{
            "test_project" => %{"root" => "/test", "exclude" => []}
          }
        })
      )

      settings = Settings.new()

      # Global approvals should default to empty map when key doesn't exist
      assert Settings.Approvals.get_approvals(settings, :global) == %{}
      assert Settings.Approvals.get_approvals(settings, :global, "shell") == []

      # Project approvals should also default to empty when missing
      Settings.set_project("test_project")
      assert Settings.Approvals.get_approvals(settings, :project) == %{}
      assert Settings.Approvals.get_approvals(settings, :project, "shell") == []
    end

    test "approvals read functions handle existing but empty approvals" do
      # Create settings with empty approvals objects
      settings_file = Settings.settings_file()

      File.write!(
        settings_file,
        Jason.encode!(%{
          "approvals" => %{},
          "projects" => %{
            "test_project" => %{"root" => "/test", "approvals" => %{}}
          }
        })
      )

      settings = Settings.new()

      # Should still return empty structures
      assert Settings.Approvals.get_approvals(settings, :global) == %{}
      assert Settings.Approvals.get_approvals(settings, :global, "shell") == []

      Settings.set_project("test_project")
      assert Settings.Approvals.get_approvals(settings, :project) == %{}
      assert Settings.Approvals.get_approvals(settings, :project, "shell") == []
    end

    test "approvals read functions handle corrupted approvals data" do
      # Create settings with corrupted approvals (not a map)
      settings_file = Settings.settings_file()

      File.write!(
        settings_file,
        Jason.encode!(%{
          "approvals" => "not_a_map",
          "projects" => %{
            "test_project" => %{"root" => "/test", "approvals" => ["not_a_map_either"]}
          }
        })
      )

      settings = Settings.new()

      # Should handle corrupted data gracefully
      assert Settings.Approvals.get_approvals(settings, :global) == %{}
      assert Settings.Approvals.get_approvals(settings, :global, "shell") == []

      Settings.set_project("test_project")
      assert Settings.Approvals.get_approvals(settings, :project) == %{}
      assert Settings.Approvals.get_approvals(settings, :project, "shell") == []
    end
  end

  describe "project data access with new format" do
    test "get_project_data works with new nested format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}
      settings = Settings.set_project_data(settings, "test_project", project_data)

      expected = project_data |> Map.put("name", "test_project")
      actual = Settings.get_project_data(settings, "test_project")
      assert actual == expected

      projects = Settings.get(settings, "projects")
      assert Map.get(projects, "test_project") == project_data
    end

    test "get_project_data falls back to old format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}
      settings = Settings.update(settings, "old_project", fn _ -> project_data end)

      expected_data = project_data |> Map.put("name", "old_project")
      assert Settings.get_project_data(settings, "old_project") == expected_data
    end

    test "set_project_data uses new nested format" do
      settings = Settings.new()
      project_data = %{"root" => "/test", "exclude" => []}

      updated_settings = Settings.set_project_data(settings, "new_project", project_data)

      projects = Settings.get(updated_settings, "projects")
      assert Map.get(projects, "new_project") == project_data
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

  describe "hint docs flags" do
    setup do
      original_enabled = Services.Globals.get_env(:fnord, :hint_docs_enabled)
      original_auto = Services.Globals.get_env(:fnord, :hint_docs_auto_inject)

      on_exit(fn ->
        if original_enabled == nil,
          do: Services.Globals.delete_env(:fnord, :hint_docs_enabled),
          else: Services.Globals.put_env(:fnord, :hint_docs_enabled, original_enabled)

        if original_auto == nil,
          do: Services.Globals.delete_env(:fnord, :hint_docs_auto_inject),
          else: Services.Globals.put_env(:fnord, :hint_docs_auto_inject, original_auto)
      end)

      :ok
    end

    test "get_hint_docs_enabled?/0 defaults to true and respects config" do
      Services.Globals.delete_env(:fnord, :hint_docs_enabled)
      assert Settings.get_hint_docs_enabled?()

      Services.Globals.put_env(:fnord, :hint_docs_enabled, false)
      refute Settings.get_hint_docs_enabled?()
    end

    test "get_hint_docs_auto_inject?/0 defaults to true and respects config" do
      Services.Globals.delete_env(:fnord, :hint_docs_auto_inject)
      assert Settings.get_hint_docs_auto_inject?()

      Services.Globals.put_env(:fnord, :hint_docs_auto_inject, false)
      refute Settings.get_hint_docs_auto_inject?()
    end
  end
end
