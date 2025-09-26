defmodule AI.Tools.File.EditAgentPatternsTest do
  @moduledoc """
  Tests for agent UX improvements based on real usage patterns observed in production logs.
  These tests verify the fixes for common agent confusion patterns.
  """
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("agent-pattern-test")
    {:ok, project: project}
  end

  setup do
    :meck.new(AI.Agent.Code.Patcher, [:no_link, :non_strict, :passthrough])
    on_exit(fn -> :meck.unload(AI.Agent.Code.Patcher) end)
    :ok
  end

  setup do
    Settings.set_edit_mode(true)
    Settings.set_auto_approve(true)

    on_exit(fn ->
      Settings.set_edit_mode(false)
      Settings.set_auto_approve(false)
    end)
  end

  describe "agent UX improvements" do
    test "file creation with omitted old_string (improved UX)", %{project: project} do
      path = Path.join(project.source_root, "agent_created.txt")

      # This pattern was confusing for agents before - now it should work seamlessly
      {:ok, result} =
        Edit.call(%{
          "file" => path,
          "create_if_missing" => true,
          "changes" => [
            %{
              "instructions" => "Create new configuration file",
              "new_string" => "# Agent-created config\nversion: 1.0\ndebug: true"
            }
          ]
        })

      assert File.exists?(path)
      assert File.read!(path) == "# Agent-created config\nversion: 1.0\ndebug: true"
      assert result.backup_file == ""

      # Verify AI patcher was not called (exact string matching)
      assert :meck.num_calls(AI.Agent.Code.Patcher, :get_response, :_) == 0
    end

    test "better error message for missing new_string", %{project: project} do
      path = Path.join(project.source_root, "test.txt")

      # Common agent mistake: providing old_string without new_string
      {:error, msg} =
        Edit.call(%{
          "file" => path,
          "changes" => [
            %{
              "instructions" => "Incomplete parameters",
              "old_string" => "something to replace"
              # missing new_string
            }
          ]
        })

      # Verify the error message is much more helpful now
      assert String.contains?(msg, "Both old_string and new_string must be provided together")
      assert String.contains?(msg, "Example for editing:")
      assert String.contains?(msg, "Example for file creation:")
      assert String.contains?(msg, "create_if_missing")
    end

    test "better error message for invalid change parameters", %{project: project} do
      path = Path.join(project.source_root, "test.txt")

      # Agent provides no valid parameters
      {:error, msg} =
        Edit.call(%{
          "file" => path,
          "changes" => [
            %{
              "description" => "This is wrong parameter name"
            }
          ]
        })

      assert String.contains?(msg, "Invalid change parameters")
      assert String.contains?(msg, "Natural language:")
      assert String.contains?(msg, "Exact matching:")
      assert String.contains?(msg, "File creation:")
      assert String.contains?(msg, "top level")
    end

    test "improved validation messages for vague instructions", %{project: project} do
      file = mock_source_file(project, "test.txt", "some content")

      {:error, msg} =
        Edit.call(%{
          "file" => file,
          # too vague
          "changes" => [%{"instructions" => "fix it"}]
        })

      # Verify the validation message provides concrete examples
      assert String.contains?(msg, "Instruction too vague")
      assert String.contains?(msg, "Examples:")
      assert String.contains?(msg, "Add error handling to the login function")
      assert String.contains?(msg, "Replace the hardcoded API URL on line 42")
    end

    test "improved validation messages for missing location anchors", %{project: project} do
      file = mock_source_file(project, "test.txt", "some content")

      {:error, msg} =
        Edit.call(%{
          "file" => file,
          "changes" => [%{"instructions" => "change something somewhere somehow"}]
        })

      # Verify the validation provides specific guidance
      assert String.contains?(msg, "lacks clear location anchors")
      assert String.contains?(msg, "Line numbers:")
      assert String.contains?(msg, "Function names:")
      assert String.contains?(msg, "Relative positions:")
      assert String.contains?(msg, "Specific text:")
    end

    test "exact string error provides parameter placement guidance", %{project: project} do
      file = mock_source_file(project, "test.txt", "content")

      {:error, msg} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "instructions" => "Replace missing text",
              "old_string" => "nonexistent text",
              "new_string" => "replacement"
            }
          ]
        })

      # Verify error message includes parameter placement guidance
      assert String.contains?(msg, "Exact string replacement failed")
      assert String.contains?(msg, "create_if_missing: true at the TOP LEVEL")
      assert String.contains?(msg, "not inside changes array")
      assert String.contains?(msg, "\"replace_all\": true")
    end

    test "natural language error provides better guidance", %{project: project} do
      file = mock_source_file(project, "test.txt", "content")

      # Mock AI patcher to fail
      :meck.expect(AI.Agent.Code.Patcher, :get_response, fn _args ->
        {:error, "AI processing failed"}
      end)

      {:error, msg} =
        Edit.call(%{
          "file" => file,
          "changes" => [
            %{
              "instructions" =>
                "Add a function to handle user authentication with proper error handling"
            }
          ]
        })

      # Verify the error message provides actionable suggestions
      assert String.contains?(msg, "Natural language instruction failed")
      assert String.contains?(msg, "Try using exact string replacement")
      assert String.contains?(msg, "old_string")
      assert String.contains?(msg, "new_string")
      assert String.contains?(msg, "TOP LEVEL")
      assert String.contains?(msg, "not inside changes")
    end

    test "content insertion confusion with create_if_missing: false", %{project: project} do
      path = Path.join(project.source_root, "test.txt")

      # Agent tries to insert content but uses create_if_missing: false inside change
      {:error, msg} =
        Edit.call(%{
          "file" => path,
          "changes" => [
            %{
              "instructions" => "Add helper function",
              "new_string" => "def helper_function, do: :ok",
              "create_if_missing" => false
            }
          ]
        })

      # Verify specific guidance for content insertion confusion
      assert String.contains?(msg, "Invalid parameters for content insertion")
      assert String.contains?(msg, "new_string without old_string")
      assert String.contains?(msg, "create_if_missing: false")
      assert String.contains?(msg, "Exact string matching - specify where to insert")
      assert String.contains?(msg, "Natural language - describe the location")
      assert String.contains?(msg, "create_if_missing belongs at the top level")
    end

    test "parameter placement error for create_if_missing", %{project: project} do
      path = Path.join(project.source_root, "test.txt")

      # Agent puts create_if_missing: true in wrong place
      {:error, msg} =
        Edit.call(%{
          "file" => path,
          "changes" => [
            %{
              "instructions" => "Create new content",
              "new_string" => "new content",
              "create_if_missing" => true
            }
          ]
        })

      # Verify guidance about parameter placement
      assert String.contains?(msg, "Parameter placement error")
      assert String.contains?(msg, "create_if_missing should be at the top level")
      assert String.contains?(msg, "not inside changes")
      assert String.contains?(msg, "Correct structure:")
      assert String.contains?(msg, "\"create_if_missing\": true")
    end
  end
end
