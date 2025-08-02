defmodule AI.Tools.FileEditorTest do
  use Fnord.TestCase

  alias AI.Tools.FileEditor

  setup do
    # FileEditor uses Once for backup management
    start_supervised(Once)

    project = mock_project("new-coder-test")
    File.mkdir_p!(project.source_root)

    {:ok, project: project}
  end

  describe "string matching functions" do
    test "normalize_for_matching/1" do
      # Use :sys.get_state to access private functions for testing
      assert FileEditor.normalize_for_matching("  hello   world  ") == "hello world"
      assert FileEditor.normalize_for_matching("Hello\n\tWorld") == "hello world"
      assert FileEditor.normalize_for_matching("") == ""
    end

    test "find_and_replace/3 with exact match" do
      content = "line1\nline2\nline3"
      old_string = "line2"
      new_string = "REPLACED"

      result = FileEditor.find_and_replace(content, old_string, new_string)

      assert {:ok, updated, %{type: :exact}} = result
      assert updated == "line1\nREPLACED\nline3"
    end

    test "find_and_replace/3 with multiple matches" do
      content = "line1\nline2\nline2\nline3"
      old_string = "line2"
      new_string = "REPLACED"

      result = FileEditor.find_and_replace(content, old_string, new_string)

      assert {:error, :multiple_matches} = result
    end

    test "find_and_replace/3 with no match" do
      content = "line1\nline2\nline3"
      old_string = "nonexistent"
      new_string = "REPLACED"

      result = FileEditor.find_and_replace(content, old_string, new_string)

      assert {:error, :not_found} = result
    end

    test "find_fuzzy_matches/2 performance test" do
      # Test with the kind of content that might be causing hanging
      content = """
      ## Features

      - Semantic search
      - On-demand explanations, documentation, and tutorials
      - Git archaeology
      - Learns about your project(s) over time
      - Improves its research capabilities with each interaction
      - User integrations
      """

      normalized_target =
        FileEditor.normalize_for_matching("""
        Features:
        - Extensive AI capabilities
        - Integration with development workflows
        - Customizable and extensible architecture
        """)

      # This should complete quickly, not hang
      start_time = System.monotonic_time(:millisecond)
      result = FileEditor.find_fuzzy_matches(content, normalized_target)
      end_time = System.monotonic_time(:millisecond)

      # Should complete in well under a second
      assert end_time - start_time < 1000
      # Should return empty list since there's no match
      assert result == []
    end

    test "find_original_boundaries/3 with edge cases" do
      content = "short content"
      normalized_target = "this is a very long target that is longer than the content itself"

      result = FileEditor.find_original_boundaries(content, 0, normalized_target)

      assert result == nil
    end
  end

  describe "full tool integration" do
    test "successful exact match edit", %{project: project} do
      content = """
      ## Features

      - Semantic search
      - Git archaeology
      - User integrations
      """

      mock_source_file(project, "test.md", content)

      args = %{
        "path" => "test.md",
        "old_string" => "- Semantic search\n- Git archaeology",
        "new_string" => "- Semantic search\n- Chain-of-thought reasoning\n- Git archaeology"
      }

      result = FileEditor.call(args)

      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"

      # Verify the content was actually changed
      full_path = Path.join(project.source_root, "test.md")
      updated_content = File.read!(full_path)
      assert updated_content =~ "Chain-of-thought reasoning"
    end

    test "safety check for overly long strings", %{project: project} do
      mock_source_file(project, "test.md", "short content")

      long_string = String.duplicate("a", 6000)

      args = %{
        "path" => "test.md",
        "old_string" => long_string,
        "new_string" => "replacement"
      }

      result = FileEditor.call(args)

      assert {:error, msg} = result

      assert msg ==
               """
               The value you supplied for `old_string` is is too long.
               The maximum length is 5000 characters.
               NO CHANGES WERE MADE.
               """
    end

    test "file not found error", %{project: _project} do
      args = %{
        "path" => "nonexistent.txt",
        "old_string" => "anything",
        "new_string" => "replacement"
      }

      result = FileEditor.call(args)

      assert {:error, msg} = result
      assert msg =~ "not found"
    end

    test "position-based splicing prevents content duplication", %{project: project} do
      content = """
      ## Features

      - Semantic search
      - On-demand explanations, documentation, and tutorials
      - Git archaeology
      - Learns about your project(s) over time
      - User integrations
      """

      mock_source_file(project, "test.md", content)

      # Test replacing just the header vs entire feature section
      args = %{
        "path" => "test.md",
        "old_string" => "## Features",
        "new_string" => "## Features\n\n- Chain-of-thought reasoning"
      }

      result = FileEditor.call(args)

      assert {:ok, _msg} = result

      # Get the result and inspect it
      updated_content = File.read!(Path.join(project.source_root, "test.md"))

      # Should contain the new feature
      assert updated_content =~ "Chain-of-thought reasoning"

      # Should still contain the original features exactly once each
      assert updated_content =~ "Semantic search"

      semantic_count =
        updated_content
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "Semantic search"))

      assert semantic_count == 1,
             "Expected 'Semantic search' to appear exactly once, found #{semantic_count} times"

      # Should not contain duplicated content
      refute String.contains?(updated_content, "## Features\n\n## Features")
    end

    test "position-based replacement of entire section", %{project: project} do
      content = """
      ## Features

      - Semantic search
      - Git archaeology
      - User integrations

      ## Installation
      """

      mock_source_file(project, "test.md", content)

      # Replace the entire features section
      args = %{
        "path" => "test.md",
        "old_string" =>
          "## Features\n\n- Semantic search\n- Git archaeology\n- User integrations",
        "new_string" =>
          "## Features\n\n- Chain-of-thought reasoning\n- Semantic search\n- Git archaeology\n- User integrations"
      }

      result = FileEditor.call(args)

      assert {:ok, _msg} = result

      updated_content = File.read!(Path.join(project.source_root, "test.md"))

      # Should contain the new feature at the top
      assert updated_content =~ "Chain-of-thought reasoning"

      # Should still have Installation section
      assert updated_content =~ "## Installation"

      # No duplication
      semantic_count =
        updated_content
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "Semantic search"))

      assert semantic_count == 1
    end
  end
end
