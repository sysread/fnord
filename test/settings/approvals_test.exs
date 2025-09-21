defmodule Settings.ApprovalsTest do
  use Fnord.TestCase, async: false

  alias Settings.Approvals

  setup do
    # Ensure clean state for each test
    File.rm_rf!(Settings.settings_file())

    # Clear any project selection from previous tests
    Services.Globals.delete_env(:fnord, :project)

    :ok
  end

  # Helper function to properly set up a project and return updated Settings struct
  defp setup_project(project_name, _project_data \\ %{"root" => "/test"}) do
    mock_project(project_name)
    Settings.new()
  end

  # ============================================================================
  # get_approvals/2 (scope-level) - Returns entire approvals map for scope
  # ============================================================================

  describe "get_approvals/2 - global scope" do
    test "returns empty map when settings file is empty" do
      settings = Settings.new()
      assert Approvals.get_approvals(settings, :global) == %{}
    end

    test "returns empty map when approvals key doesn't exist" do
      # Create settings file without approvals key
      settings_path = Settings.settings_file()
      File.write!(settings_path, ~s({"projects": {}}))

      settings = Settings.new()
      assert Approvals.get_approvals(settings, :global) == %{}
    end

    test "returns empty map when approvals is null" do
      settings_path = Settings.settings_file()
      File.write!(settings_path, ~s({"approvals": null}))

      settings = Settings.new()
      assert Approvals.get_approvals(settings, :global) == %{}
    end

    test "returns populated approvals map when it exists" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git")
        |> Approvals.approve(:global, "shell_full", "^find")
        |> Approvals.approve(:global, "edit", "important.txt")

      result = Approvals.get_approvals(settings, :global)
      assert result["shell"] == ["git"]
      assert result["shell_full"] == ["^find"]
      assert result["edit"] == ["important.txt"]
    end
  end

  describe "get_approvals/2 - project scope" do
    test "returns empty map when no project is selected" do
      settings = Settings.new()
      assert Approvals.get_approvals(settings, :project) == %{}
    end

    test "returns empty map when selected project doesn't exist" do
      Settings.set_project("nonexistent")
      settings = Settings.new()
      assert Approvals.get_approvals(settings, :project) == %{}
    end

    test "returns empty map when project exists but has no approvals key" do
      settings = setup_project("test-project")
      assert Approvals.get_approvals(settings, :project) == %{}
    end

    test "returns populated approvals map when project has approvals" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:project, "shell", "npm")
        |> Approvals.approve(:project, "edit", "package.json")

      result = Approvals.get_approvals(settings, :project)
      assert result["shell"] == ["npm"]
      assert result["edit"] == ["package.json"]
    end

    test "handles old format projects correctly" do
      Settings.set_project("old-project")

      # Create old format project data directly at root level
      settings_path = Settings.settings_file()

      old_format_data = %{
        "old-project" => %{
          "root" => "/old/path",
          "approvals" => %{
            "shell" => ["mix"]
          }
        },
        "approvals" => %{}
      }

      File.write!(settings_path, Jason.encode!(old_format_data))

      settings = Settings.new()
      result = Approvals.get_approvals(settings, :project)
      assert result["shell"] == ["mix"]
    end

    test "handles new format projects correctly" do
      Settings.set_project("new-project")

      settings_path = Settings.settings_file()

      new_format_data = %{
        "approvals" => %{},
        "projects" => %{
          "new-project" => %{
            "root" => "/new/path",
            "approvals" => %{
              "shell" => ["cargo"]
            }
          }
        }
      }

      File.write!(settings_path, Jason.encode!(new_format_data))

      settings = Settings.new()
      result = Approvals.get_approvals(settings, :project)
      assert result["shell"] == ["cargo"]
    end
  end

  # ============================================================================
  # get_approvals/3 (kind-level) - Returns list of approvals for specific kind
  # ============================================================================

  describe "get_approvals/3 - global scope with kinds" do
    test "returns empty list when kind doesn't exist" do
      settings = Settings.new()
      assert Approvals.get_approvals(settings, :global, "nonexistent") == []
    end

    test "returns empty list when kind exists but is empty" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git")

      # Delete the approval to leave empty list
      Settings.update(settings, "approvals", fn approvals ->
        Map.put(approvals, "shell", [])
      end)
      |> then(fn updated_settings ->
        assert Approvals.get_approvals(updated_settings, :global, "shell") == []
      end)
    end

    test "returns populated list when kind has approvals" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git")
        |> Approvals.approve(:global, "shell", "npm")
        |> Approvals.approve(:global, "shell", "mix")

      result = Approvals.get_approvals(settings, :global, "shell")
      # Should be sorted
      assert result == ["git", "mix", "npm"]
    end

    test "handles corrupted kind data gracefully" do
      settings_path = Settings.settings_file()

      corrupted_data = %{
        "approvals" => %{
          "shell" => "not-a-list",
          "valid_kind" => ["item1"]
        }
      }

      File.write!(settings_path, Jason.encode!(corrupted_data))

      settings = Settings.new()
      # Corrupted data should return empty list
      assert Approvals.get_approvals(settings, :global, "shell") == []
      # Valid data should work normally
      assert Approvals.get_approvals(settings, :global, "valid_kind") == ["item1"]
    end
  end

  describe "get_approvals/3 - project scope with kinds" do
    test "returns empty list when no project selected" do
      settings = Settings.new()
      assert Approvals.get_approvals(settings, :project, "shell") == []
    end

    test "returns empty list when project exists but kind doesn't" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:project, "shell", "git")

      assert Approvals.get_approvals(settings, :project, "nonexistent") == []
    end

    test "returns populated list when project kind has approvals" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:project, "shell", "mix")
        |> Approvals.approve(:project, "shell", "cargo")

      result = Approvals.get_approvals(settings, :project, "shell")
      # Should be sorted
      assert result == ["cargo", "mix"]
    end
  end

  # ============================================================================
  # approve/4 - Adding new approvals to settings
  # ============================================================================

  describe "approve/4 - global scope" do
    test "creates approvals structure when it doesn't exist" do
      settings = Settings.new()
      updated = Approvals.approve(settings, :global, "shell", "git")

      assert Approvals.get_approvals(updated, :global, "shell") == ["git"]
    end

    test "creates kind when it doesn't exist in existing approvals" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "existing", "item")

      updated = Approvals.approve(settings, :global, "shell", "git")

      assert Approvals.get_approvals(updated, :global, "existing") == ["item"]
      assert Approvals.get_approvals(updated, :global, "shell") == ["git"]
    end

    test "adds to existing kind without duplicating" do
      Settings.new()
      |> Approvals.approve(:global, "shell", "git")
      |> Approvals.approve(:global, "shell", "npm")
      # duplicate
      |> Approvals.approve(:global, "shell", "git")

      result =
        Settings.new()
        |> Approvals.get_approvals(:global, "shell")

      # Should be deduplicated and sorted
      assert result == ["git", "npm"]
    end

    test "maintains sorting when adding items" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "npm")
        |> Approvals.approve(:global, "shell", "cargo")
        |> Approvals.approve(:global, "shell", "mix")
        |> Approvals.approve(:global, "shell", "git")

      result = Approvals.get_approvals(settings, :global, "shell")
      assert result == ["cargo", "git", "mix", "npm"]
    end

    test "handles corrupted approvals data by recreating structure" do
      # Create corrupted approvals data
      settings_path = Settings.settings_file()
      File.write!(settings_path, ~s({"approvals": "corrupted"}))

      settings = Settings.new()
      updated = Approvals.approve(settings, :global, "shell", "git")

      assert Approvals.get_approvals(updated, :global, "shell") == ["git"]
    end

    test "preserves existing approvals when adding new kinds" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git")
        |> Approvals.approve(:global, "edit", "important.txt")

      updated = Approvals.approve(settings, :global, "new_kind", "new_item")

      assert Approvals.get_approvals(updated, :global, "shell") == ["git"]
      assert Approvals.get_approvals(updated, :global, "edit") == ["important.txt"]
      assert Approvals.get_approvals(updated, :global, "new_kind") == ["new_item"]
    end
  end

  describe "approve/4 - project scope" do
    test "returns unchanged settings when no project is selected" do
      settings = Settings.new()
      original_data = settings.data

      updated = Approvals.approve(settings, :project, "shell", "git")
      assert updated.data == original_data
    end

    test "creates project approvals structure when project exists but has no approvals" do
      settings = setup_project("test-project")
      updated = Approvals.approve(settings, :project, "shell", "mix")

      assert Approvals.get_approvals(updated, :project, "shell") == ["mix"]
    end

    test "adds to existing project approvals without duplicating" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:project, "shell", "mix")
        |> Approvals.approve(:project, "shell", "cargo")
        # duplicate
        |> Approvals.approve(:project, "shell", "mix")

      result = Approvals.get_approvals(settings, :project, "shell")
      assert result == ["cargo", "mix"]
    end

    test "creates projects structure when it doesn't exist" do
      Settings.set_project("new-project")

      # Start with completely empty settings
      settings_path = Settings.settings_file()
      File.write!(settings_path, "{}")

      settings = Settings.new()
      updated = Approvals.approve(settings, :project, "shell", "mix")

      # Project should be created in new format
      projects = Settings.get(updated, "projects", %{})
      assert projects["new-project"]["approvals"]["shell"] == ["mix"]
    end

    test "preserves other projects when adding approvals" do
      # Create project1 and add initial approval
      mock_project("project1")
      _settings1 = Settings.new() |> Approvals.approve(:project, "shell", "git")

      # Create project2 and add initial approval
      mock_project("project2")
      _settings2 = Settings.new() |> Approvals.approve(:project, "edit", "file1.txt")

      # Switch back to project1 and add another approval to the existing project
      set_config(:project, "project1")
      updated_settings = Settings.new() |> Approvals.approve(:project, "shell", "npm")

      # project1 should have both approvals
      result1 = Approvals.get_approvals(updated_settings, :project, "shell")
      assert "npm" in result1
      assert "git" in result1

      # project2 should still have its original approval
      set_config(:project, "project2")
      result2 = Approvals.get_approvals(Settings.new(), :project, "edit")
      assert result2 == ["file1.txt"]
    end
  end

  # ============================================================================
  # approved?/3 and approved?/4 - Regex-based approval checking
  # ============================================================================

  describe "approved?/3 - combined scope checking" do
    test "returns false when no approvals exist in either scope" do
      settings = setup_project("test-project")
      refute Approvals.approved?(settings, "shell", "git status")
    end

    test "returns true when global approval matches" do
      # Set up project context
      setup_project("test-project")

      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git.*")

      assert Approvals.approved?(settings, "shell", "git status")
      refute Approvals.approved?(settings, "shell", "npm install")
    end

    test "returns true when project approval matches" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:project, "shell", "npm.*")

      assert Approvals.approved?(settings, "shell", "npm install")
      refute Approvals.approved?(settings, "shell", "git status")
    end

    test "returns true when either scope matches" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:global, "shell", "git.*")
        |> Approvals.approve(:project, "shell", "npm.*")

      assert Approvals.approved?(settings, "shell", "git status")
      assert Approvals.approved?(settings, "shell", "npm install")
      refute Approvals.approved?(settings, "shell", "cargo build")
    end

    test "handles multiple patterns in same scope" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git.*")
        |> Approvals.approve(:global, "shell", "npm.*")
        |> Approvals.approve(:global, "shell", "^cargo build$")

      assert Approvals.approved?(settings, "shell", "git status")
      assert Approvals.approved?(settings, "shell", "npm install --save")
      assert Approvals.approved?(settings, "shell", "cargo build")
      refute Approvals.approved?(settings, "shell", "cargo build --release")
    end
  end

  describe "approved?/4 - scope-specific checking" do
    test "checks only specified scope" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:global, "shell", "git.*")
        |> Approvals.approve(:project, "shell", "npm.*")

      assert Approvals.approved?(settings, :global, "shell", "git status")
      refute Approvals.approved?(settings, :global, "shell", "npm install")

      assert Approvals.approved?(settings, :project, "shell", "npm install")
      refute Approvals.approved?(settings, :project, "shell", "git status")
    end

    test "returns false for empty approval lists" do
      settings = Settings.new()
      refute Approvals.approved?(settings, :global, "shell", "any command")

      settings = setup_project("test-project")
      refute Approvals.approved?(settings, :project, "shell", "any command")
    end
  end

  # ============================================================================
  # prefix_approved?/3 and prefix_approved?/4 - Prefix-based approval checking
  # ============================================================================

  describe "prefix_approved?/3 - combined scope checking" do
    test "returns false when no approvals exist" do
      settings = setup_project("test-project")
      refute Approvals.prefix_approved?(settings, "shell", "git status")
    end

    test "returns true when global prefix matches" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git")

      assert Approvals.prefix_approved?(settings, "shell", "git status")
      assert Approvals.prefix_approved?(settings, "shell", "git")
      refute Approvals.prefix_approved?(settings, "shell", "npm install")
    end

    test "returns true when project prefix matches" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:project, "shell", "npm")

      assert Approvals.prefix_approved?(settings, "shell", "npm install")
      assert Approvals.prefix_approved?(settings, "shell", "npm")
      refute Approvals.prefix_approved?(settings, "shell", "git status")
    end

    test "returns true when either scope has matching prefix" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:global, "shell", "git")
        |> Approvals.approve(:project, "shell", "npm")

      assert Approvals.prefix_approved?(settings, "shell", "git status")
      assert Approvals.prefix_approved?(settings, "shell", "npm install")
      refute Approvals.prefix_approved?(settings, "shell", "cargo build")
    end

    test "handles multiple prefixes correctly" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git")
        |> Approvals.approve(:global, "shell", "npm")
        |> Approvals.approve(:global, "shell", "cargo")

      assert Approvals.prefix_approved?(settings, "shell", "git status")
      assert Approvals.prefix_approved?(settings, "shell", "npm install")
      assert Approvals.prefix_approved?(settings, "shell", "cargo build")
      refute Approvals.prefix_approved?(settings, "shell", "mix test")
    end

    test "handles partial prefix matches correctly" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git log")

      assert Approvals.prefix_approved?(settings, "shell", "git log --oneline")
      refute Approvals.prefix_approved?(settings, "shell", "git status")
      refute Approvals.prefix_approved?(settings, "shell", "git")
    end
  end

  describe "prefix_approved?/4 - scope-specific checking" do
    test "checks only specified scope for prefix matches" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:global, "shell", "git")
        |> Approvals.approve(:project, "shell", "npm")

      assert Approvals.prefix_approved?(settings, :global, "shell", "git status")
      refute Approvals.prefix_approved?(settings, :global, "shell", "npm install")

      assert Approvals.prefix_approved?(settings, :project, "shell", "npm install")
      refute Approvals.prefix_approved?(settings, :project, "shell", "git status")
    end

    test "returns false for empty prefix lists" do
      settings = Settings.new()
      refute Approvals.prefix_approved?(settings, :global, "shell", "any command")

      settings = setup_project("test-project")
      refute Approvals.prefix_approved?(settings, :project, "shell", "any command")
    end
  end

  # ============================================================================
  # Edge Cases and Data Corruption Scenarios
  # ============================================================================

  describe "data corruption and edge cases" do
    test "handles completely corrupted settings file" do
      settings_path = Settings.settings_file()
      File.write!(settings_path, "invalid json {")

      # Should raise with helpful error message
      assert_raise RuntimeError, ~r/Corrupted settings file/, fn ->
        Settings.new()
      end
    end

    test "handles null values gracefully" do
      settings_path = Settings.settings_file()

      corrupted_data = %{
        "approvals" => %{
          "shell" => nil,
          "edit" => ["valid"]
        }
      }

      File.write!(settings_path, Jason.encode!(corrupted_data))

      settings = Settings.new()
      assert Approvals.get_approvals(settings, :global, "shell") == []
      assert Approvals.get_approvals(settings, :global, "edit") == ["valid"]
    end

    test "handles mixed data types in approval lists" do
      settings_path = Settings.settings_file()

      mixed_data = %{
        "approvals" => %{
          "shell" => ["string", 123, nil, true, "another_string"]
        }
      }

      File.write!(settings_path, Jason.encode!(mixed_data))

      settings = Settings.new()
      # Should filter out non-strings or handle gracefully
      result = Approvals.get_approvals(settings, :global, "shell")
      # The exact behavior depends on implementation - test documents current behavior
      assert is_list(result)
    end

    test "handles empty strings in approval lists" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "")
        |> Approvals.approve(:global, "shell", "git")

      result = Approvals.get_approvals(settings, :global, "shell")
      assert "" in result
      assert "git" in result
    end

    test "handles very long approval lists" do
      settings = Settings.new()

      # Add 500 approvals sequentially (can't be parallelized due to immutable state)
      large_settings =
        Enum.reduce(1..500, settings, fn i, acc ->
          Approvals.approve(acc, :global, "shell", "command_#{i}")
        end)

      result = Approvals.get_approvals(large_settings, :global, "shell")
      assert length(result) == 500
      assert "command_1" in result
      assert "command_500" in result
    end

    test "handles unicode and special characters" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git命令")
        |> Approvals.approve(:global, "shell", "npm-🚀")
        |> Approvals.approve(:global, "shell", "special/chars\\and\"quotes")

      result = Approvals.get_approvals(settings, :global, "shell")
      assert "git命令" in result
      assert "npm-🚀" in result
      assert "special/chars\\and\"quotes" in result
    end
  end

  # ============================================================================
  # Integration and Cross-Scope Testing
  # ============================================================================

  describe "cross-scope interactions" do
    test "global and project approvals don't interfere with each other" do
      settings =
        setup_project("test-project")
        |> Approvals.approve(:global, "shell", "git")
        |> Approvals.approve(:project, "shell", "npm")

      # Both should be retrievable independently
      global_shell = Approvals.get_approvals(settings, :global, "shell")
      project_shell = Approvals.get_approvals(settings, :project, "shell")

      assert global_shell == ["git"]
      assert project_shell == ["npm"]

      # Combined checking should find both
      assert Approvals.prefix_approved?(settings, "shell", "git status")
      assert Approvals.prefix_approved?(settings, "shell", "npm install")
    end

    test "different kinds don't interfere with each other" do
      settings =
        Settings.new()
        |> Approvals.approve(:global, "shell", "git")
        |> Approvals.approve(:global, "edit", "important.txt")
        |> Approvals.approve(:global, "shell_full", "^npm.*")

      assert Approvals.get_approvals(settings, :global, "shell") == ["git"]
      assert Approvals.get_approvals(settings, :global, "edit") == ["important.txt"]
      assert Approvals.get_approvals(settings, :global, "shell_full") == ["^npm.*"]
    end

    test "multiple projects maintain separate approval spaces" do
      # Set up two projects with different approvals
      settings_path = Settings.settings_file()

      multi_project_data = %{
        "approvals" => %{"global_kind" => ["global_item"]},
        "projects" => %{
          "project1" => %{
            "name" => "project1",
            "root" => "/path1",
            "approvals" => %{"shell" => ["git"]}
          },
          "project2" => %{
            "name" => "project2",
            "root" => "/path2",
            "approvals" => %{"shell" => ["npm"]}
          }
        }
      }

      File.write!(settings_path, Jason.encode!(multi_project_data))

      # Test project1 - set application env and create settings
      Services.Globals.put_env(:fnord, :project, "project1")
      project1_approvals = Approvals.get_approvals(Settings.new(), :project, "shell")
      assert project1_approvals == ["git"]

      # Test project2 - set application env and create settings
      Services.Globals.put_env(:fnord, :project, "project2")
      project2_approvals = Approvals.get_approvals(Settings.new(), :project, "shell")
      assert project2_approvals == ["npm"]

      # Global approvals should be accessible from both
      Services.Globals.put_env(:fnord, :project, "project1")
      global_from_p1 = Approvals.get_approvals(Settings.new(), :global, "global_kind")
      Services.Globals.put_env(:fnord, :project, "project2")
      global_from_p2 = Approvals.get_approvals(Settings.new(), :global, "global_kind")

      assert global_from_p1 == ["global_item"]
      assert global_from_p2 == ["global_item"]
    end
  end
end
