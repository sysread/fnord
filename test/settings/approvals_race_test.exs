defmodule Settings.Approvals.RaceTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("blarg")
    %{project: project}
  end

  describe "repair_approval_list race condition handling" do
    test "global repair merges concurrent additions instead of overwriting", %{home_dir: _} do
      # Setup: Create settings with some valid approvals and one invalid entry
      settings_file = Settings.settings_file()

      initial_data = %{
        "approvals" => %{
          # 123 is invalid
          "shell" => ["git status", 123, "git log"],
          "edit" => ["*.ex", "*.exs"]
        }
      }

      File.write!(settings_file, Jason.encode!(initial_data))

      # Simulate what happens when repair is triggered
      settings = Settings.new()

      # Before fix: repair would have written back only ["git status", "git log"]
      # After fix: repair should preserve any concurrent additions

      # Simulate concurrent addition by another process
      # (In real scenario, this would happen between validation detecting corruption
      # and the repair write)
      Services.Globals.Spawn.spawn(fn ->
        # Small delay to interleave with repair
        :timer.sleep(5)

        Settings.new()
        |> Settings.update("approvals", fn approvals ->
          current_shell = Map.get(approvals, "shell", [])
          # Add a new approval while repair is running
          updated = (current_shell ++ ["git diff"]) |> Enum.uniq() |> Enum.sort()
          Map.put(approvals, "shell", updated)
        end)
      end)

      # Trigger validation which will detect the invalid entry and repair
      result = Settings.Approvals.get_approvals(settings, :global, "shell")

      # The result should have filtered out the invalid entry (123)
      refute 123 in result
      assert "git status" in result
      assert "git log" in result

      # Wait for concurrent process to complete
      :timer.sleep(50)

      # Verify the concurrent addition wasn't lost
      final_approvals = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")
      assert "git status" in final_approvals
      assert "git log" in final_approvals
      assert "git diff" in final_approvals
      refute 123 in final_approvals
    end

    test "project repair merges concurrent additions instead of overwriting" do
      # Use set_config to set the project properly in test context
      set_config(:project, "test_project")

      # Setup: Create settings with project approvals containing invalid entry
      settings_file = Settings.settings_file()

      initial_data = %{
        "projects" => %{
          "test_project" => %{
            "root" => "/test",
            "approvals" => %{
              # nil is invalid
              "shell" => ["mix test", nil, "mix compile"],
              "edit" => ["lib/**/*.ex"]
            }
          }
        }
      }

      File.write!(settings_file, Jason.encode!(initial_data))

      settings = Settings.new()

      # Simulate concurrent addition
      Services.Globals.Spawn.spawn(fn ->
        :timer.sleep(5)

        Settings.new()
        |> Settings.update("projects", fn projects ->
          project = Map.get(projects, "test_project", %{})
          approvals = Map.get(project, "approvals", %{})
          shell_approvals = Map.get(approvals, "shell", [])
          updated = (shell_approvals ++ ["mix format"]) |> Enum.uniq() |> Enum.sort()
          updated_approvals = Map.put(approvals, "shell", updated)
          updated_project = Map.put(project, "approvals", updated_approvals)
          Map.put(projects, "test_project", updated_project)
        end)
      end)

      # Trigger validation and repair
      result = Settings.Approvals.get_approvals(settings, :project, "shell")

      # Invalid entry should be filtered
      refute nil in result
      assert "mix test" in result
      assert "mix compile" in result

      # Wait and verify concurrent addition wasn't lost
      :timer.sleep(50)
      final_approvals = Settings.Approvals.get_approvals(Settings.new(), :project, "shell")
      assert "mix test" in final_approvals
      assert "mix compile" in final_approvals
      assert "mix format" in final_approvals
      refute nil in final_approvals
    end

    test "repair handles completely corrupted approval data (not a list)", %{home_dir: _} do
      # Test when the approval data is completely wrong type
      settings_file = Settings.settings_file()

      initial_data = %{
        "approvals" => %{
          # Completely wrong type
          "shell" => "not_a_list",
          "edit" => ["*.ex"]
        }
      }

      File.write!(settings_file, Jason.encode!(initial_data))

      settings = Settings.new()

      # Simulate concurrent addition while repair is fixing corruption
      Services.Globals.Spawn.spawn(fn ->
        :timer.sleep(5)

        Settings.new()
        |> Settings.update("approvals", fn approvals ->
          # Since shell is corrupted, we need to handle it being non-list
          current_shell =
            case Map.get(approvals, "shell") do
              list when is_list(list) -> list
              _ -> []
            end

          updated = (current_shell ++ ["git status"]) |> Enum.uniq() |> Enum.sort()
          Map.put(approvals, "shell", updated)
        end)
      end)

      # This should trigger repair since "not_a_list" is invalid
      result = Settings.Approvals.get_approvals(settings, :global, "shell")
      # Initial result is empty due to corruption
      assert result == []

      # Wait and verify the concurrent addition succeeded
      :timer.sleep(50)
      final_approvals = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")
      assert final_approvals == ["git status"]
    end

    test "repair handles nil approval data", %{home_dir: _} do
      settings_file = Settings.settings_file()

      initial_data = %{
        "approvals" => %{
          # nil instead of list
          "shell" => nil,
          "edit" => ["*.ex"]
        }
      }

      File.write!(settings_file, Jason.encode!(initial_data))

      settings = Settings.new()

      # Concurrent addition
      Services.Globals.Spawn.spawn(fn ->
        :timer.sleep(5)

        Settings.new()
        |> Settings.update("approvals", fn approvals ->
          current = Map.get(approvals, "shell", [])

          updated =
            if is_list(current) do
              (current ++ ["ls -la"]) |> Enum.uniq() |> Enum.sort()
            else
              ["ls -la"]
            end

          Map.put(approvals, "shell", updated)
        end)
      end)

      # Trigger repair
      result = Settings.Approvals.get_approvals(settings, :global, "shell")
      assert result == []

      # Verify concurrent addition survived
      :timer.sleep(50)
      final_approvals = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")
      assert final_approvals == ["ls -la"]
    end

    test "multiple concurrent repairs don't lose data", %{home_dir: _} do
      # Test multiple processes all trying to repair at once
      settings_file = Settings.settings_file()

      initial_data = %{
        "approvals" => %{
          "shell" => [
            "valid1",
            # invalid
            123,
            "valid2",
            # invalid
            nil,
            "valid3"
          ]
        }
      }

      File.write!(settings_file, Jason.encode!(initial_data))

      # Start multiple concurrent processes that will all detect and try to repair
      tasks =
        for i <- 1..50 do
          Services.Globals.Spawn.async(fn ->
            :timer.sleep(Enum.random(1..10))

            settings = Settings.new()

            # Each process adds its own approval
            Settings.Approvals.approve(settings, :global, "shell", "process_#{i}")

            # Then triggers validation/repair by reading
            Settings.Approvals.get_approvals(settings, :global, "shell")
          end)
        end

      # Wait for all tasks
      Enum.each(tasks, fn task -> Task.await(task, 5000) end)

      # Verify all data is preserved
      final = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")

      # Original valid entries should be there
      assert "valid1" in final
      assert "valid2" in final
      assert "valid3" in final

      # All process additions should be there
      assert "process_1" in final
      assert "process_2" in final
      assert "process_3" in final
      assert "process_4" in final
      assert "process_5" in final

      # Invalid entries should be gone
      refute 123 in final
      refute nil in final
    end

    test "repair preserves valid non-string entries that should be strings", %{home_dir: _} do
      # Some entries might be atoms that got serialized wrong
      settings_file = Settings.settings_file()

      initial_data = %{
        "approvals" => %{
          "shell" => [
            "git status",
            # Invalid: map instead of string
            %{"invalid" => "map"},
            "git log",
            # Invalid: nested list
            ["nested", "list"],
            "git diff"
          ]
        }
      }

      File.write!(settings_file, Jason.encode!(initial_data))

      settings = Settings.new()

      # Concurrent addition during repair
      Services.Globals.Spawn.spawn(fn ->
        :timer.sleep(5)

        Settings.new()
        |> Settings.Approvals.approve(:global, "shell", "git pull")
      end)

      # Trigger repair
      result = Settings.Approvals.get_approvals(settings, :global, "shell")

      # Should have valid strings only
      assert "git status" in result
      assert "git log" in result
      assert "git diff" in result
      refute %{"invalid" => "map"} in result
      refute ["nested", "list"] in result

      # Wait and check final state
      :timer.sleep(50)
      final = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")
      assert "git status" in final
      assert "git log" in final
      assert "git diff" in final
      assert "git pull" in final
      refute %{"invalid" => "map"} in final
      refute ["nested", "list"] in final
    end
  end

  describe "approval additions don't lose concurrent updates" do
    test "two processes adding different approvals to same kind", %{home_dir: _} do
      # Start with empty approvals
      Settings.new()

      # Two processes add different approvals concurrently
      task1 =
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "shell", "git status")
        end)

      task2 =
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "shell", "git log")
        end)

      Task.await(task1, 5000)
      Task.await(task2, 5000)

      # Both should be present
      final = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")
      assert "git status" in final
      assert "git log" in final
    end

    test "many processes adding approvals concurrently", %{home_dir: _} do
      # Start with some existing approvals
      Settings.new()
      |> Settings.Approvals.approve(:global, "shell", "existing_1")
      |> Settings.Approvals.approve(:global, "shell", "existing_2")

      # Many processes add approvals concurrently
      tasks =
        for i <- 1..10 do
          Services.Globals.Spawn.async(fn ->
            Settings.new()
            |> Settings.Approvals.approve(:global, "shell", "cmd_#{i}")
          end)
        end

      Enum.each(tasks, fn task -> Task.await(task, 10000) end)

      # All should be present
      final = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")
      assert "existing_1" in final
      assert "existing_2" in final

      for i <- 1..10 do
        assert "cmd_#{i}" in final
      end
    end

    test "concurrent approvals to different kinds don't interfere", %{home_dir: _} do
      # Multiple processes updating different kinds
      tasks = [
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "shell", "git status")
        end),
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "edit", "*.ex")
        end),
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "shell_full", "^find.*")
        end)
      ]

      Enum.each(tasks, fn task -> Task.await(task, 5000) end)

      # Each kind should have its approval
      settings = Settings.new()
      assert Settings.Approvals.get_approvals(settings, :global, "shell") == ["git status"]
      assert Settings.Approvals.get_approvals(settings, :global, "edit") == ["*.ex"]
      assert Settings.Approvals.get_approvals(settings, :global, "shell_full") == ["^find.*"]
    end
  end
end
