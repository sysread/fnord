defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase

  setup do
    project = mock_project("new-coder-test")
    File.mkdir_p!(project.source_root)

    {:ok, project: project}
  end

  describe "string matching functions" do
    test "normalize_for_matching/1" do
      # Use :sys.get_state to access private functions for testing
      assert AI.Tools.File.Edit.normalize_for_matching("  hello   world  ") == "hello world"
      assert AI.Tools.File.Edit.normalize_for_matching("Hello\n\tWorld") == "hello world"
      assert AI.Tools.File.Edit.normalize_for_matching("") == ""
    end

    test "find_and_replace/3 with exact match" do
      content = "line1\nline2\nline3"
      old_string = "line2"
      new_string = "REPLACED"

      result = AI.Tools.File.Edit.find_and_replace(content, old_string, new_string)

      assert {:ok, updated, %{type: :exact}} = result
      assert updated == "line1\nREPLACED\nline3"
    end

    test "find_and_replace/3 with multiple matches" do
      content = "line1\nline2\nline2\nline3"
      old_string = "line2"
      new_string = "REPLACED"

      result = AI.Tools.File.Edit.find_and_replace(content, old_string, new_string)

      assert {:error, :multiple_matches} = result
    end

    test "find_and_replace/3 with no match" do
      content = "line1\nline2\nline3"
      old_string = "nonexistent"
      new_string = "REPLACED"

      result = AI.Tools.File.Edit.find_and_replace(content, old_string, new_string)

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
        AI.Tools.File.Edit.normalize_for_matching("""
        Features:
        - Extensive AI capabilities
        - Integration with development workflows
        - Customizable and extensible architecture
        """)

      # This should complete quickly, not hang
      start_time = System.monotonic_time(:millisecond)
      result = AI.Tools.File.Edit.find_fuzzy_matches(content, normalized_target)
      end_time = System.monotonic_time(:millisecond)

      # Should complete in well under a second
      assert end_time - start_time < 1000
      # Should return empty list since there's no match
      assert result == []
    end

    test "find_original_boundaries/3 with edge cases" do
      content = "short content"
      normalized_target = "this is a very long target that is longer than the content itself"

      result = AI.Tools.File.Edit.find_original_boundaries(content, 0, normalized_target)

      assert result == nil
    end
  end

  describe "successful editing operations" do
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

      result = AI.Tools.File.Edit.call(args)

      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"

      # Verify the content was actually changed
      full_path = Path.join(project.source_root, "test.md")
      updated_content = File.read!(full_path)
      assert updated_content =~ "Chain-of-thought reasoning"
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

      result = AI.Tools.File.Edit.call(args)

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

      result = AI.Tools.File.Edit.call(args)

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


  describe "file truncation and deletion operations" do
    test "truncating file to empty contents", %{project: project} do
      # Create a file with some content
      content = """
      Line 1
      Line 2
      Line 3
      Some content here
      More content
      """
      
      mock_source_file(project, "to_truncate.txt", content)
      full_path = Path.join(project.source_root, "to_truncate.txt")
      
      # Verify initial content exists
      assert File.read!(full_path) == content
      
      # Truncate the entire file to empty by replacing all content with empty string
      args = %{
        "path" => "to_truncate.txt",
        "old_string" => content,
        "new_string" => ""
      }
      
      result = AI.Tools.File.Edit.call(args)
      
      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"
      
      # Verify the file still exists but is now empty
      assert File.exists?(full_path)
      truncated_content = File.read!(full_path)
      assert truncated_content == ""
      assert String.length(truncated_content) == 0
    end

    test "removing first few lines of a file", %{project: project} do
      content = """
      Line 1 - to be removed
      Line 2 - to be removed
      Line 3 - to be removed
      Line 4 - to keep
      Line 5 - to keep
      Line 6 - to keep
      """
      
      mock_source_file(project, "remove_first_lines.txt", content)
      full_path = Path.join(project.source_root, "remove_first_lines.txt")
      
      # Remove first 3 lines by replacing them with nothing
      args = %{
        "path" => "remove_first_lines.txt",
        "old_string" => "Line 1 - to be removed\nLine 2 - to be removed\nLine 3 - to be removed\n",
        "new_string" => ""
      }
      
      result = AI.Tools.File.Edit.call(args)
      
      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"
      
      # Verify only the last 3 lines remain
      updated_content = File.read!(full_path)
      expected = """
      Line 4 - to keep
      Line 5 - to keep
      Line 6 - to keep
      """
      
      assert updated_content == expected
      refute updated_content =~ "Line 1 - to be removed"
      refute updated_content =~ "Line 2 - to be removed"
      refute updated_content =~ "Line 3 - to be removed"
    end

    test "removing last few lines of a file", %{project: project} do
      content = """
      Line 1 - to keep
      Line 2 - to keep
      Line 3 - to keep
      Line 4 - to be removed
      Line 5 - to be removed
      Line 6 - to be removed
      """
      
      mock_source_file(project, "remove_last_lines.txt", content)
      full_path = Path.join(project.source_root, "remove_last_lines.txt")
      
      # Remove last 3 lines by replacing them with nothing
      args = %{
        "path" => "remove_last_lines.txt",
        "old_string" => "Line 4 - to be removed\nLine 5 - to be removed\nLine 6 - to be removed\n",
        "new_string" => ""
      }
      
      result = AI.Tools.File.Edit.call(args)
      
      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"
      
      # Verify only the first 3 lines remain
      updated_content = File.read!(full_path)
      expected = """
      Line 1 - to keep
      Line 2 - to keep
      Line 3 - to keep
      """
      
      assert updated_content == expected
      refute updated_content =~ "Line 4 - to be removed"
      refute updated_content =~ "Line 5 - to be removed"
      refute updated_content =~ "Line 6 - to be removed"
    end

    test "edge case: removing first line only", %{project: project} do
      content = """
      First line to remove
      Second line to keep
      Third line to keep
      """
      
      mock_source_file(project, "remove_first_only.txt", content)
      full_path = Path.join(project.source_root, "remove_first_only.txt")
      
      # Remove just the first line including its newline
      args = %{
        "path" => "remove_first_only.txt",
        "old_string" => "First line to remove\n",
        "new_string" => ""
      }
      
      result = AI.Tools.File.Edit.call(args)
      
      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"
      
      updated_content = File.read!(full_path)
      expected = """
      Second line to keep
      Third line to keep
      """
      
      assert updated_content == expected
      refute updated_content =~ "First line to remove"
    end

    test "edge case: removing last line only", %{project: project} do
      content = """
      First line to keep
      Second line to keep
      Last line to remove
      """
      
      mock_source_file(project, "remove_last_only.txt", content)
      full_path = Path.join(project.source_root, "remove_last_only.txt")
      
      # Remove just the last line including its newline
      args = %{
        "path" => "remove_last_only.txt",
        "old_string" => "Last line to remove\n",
        "new_string" => ""
      }
      
      result = AI.Tools.File.Edit.call(args)
      
      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"
      
      updated_content = File.read!(full_path)
      expected = """
      First line to keep
      Second line to keep
      """
      
      assert updated_content == expected
      refute updated_content =~ "Last line to remove"
    end
  end

  describe "newline handling edge cases" do
    test "editing file with trailing newline", %{project: project} do
      # File content with trailing newline (common case)
      content = "Line 1\nLine 2\nLine 3\n"
      
      mock_source_file(project, "with_trailing_newline.txt", content)
      full_path = Path.join(project.source_root, "with_trailing_newline.txt")
      
      # Replace middle line while preserving trailing newline
      args = %{
        "path" => "with_trailing_newline.txt",
        "old_string" => "Line 2",
        "new_string" => "Modified Line 2"
      }
      
      result = AI.Tools.File.Edit.call(args)
      
      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"
      
      # Verify the edit worked and trailing newline is preserved
      updated_content = File.read!(full_path)
      expected = "Line 1\nModified Line 2\nLine 3\n"
      
      assert updated_content == expected
      assert String.ends_with?(updated_content, "\n")
      
      # Test removing the last line including its newline
      args2 = %{
        "path" => "with_trailing_newline.txt",
        "old_string" => "Line 3\n",
        "new_string" => ""
      }
      
      result2 = AI.Tools.File.Edit.call(args2)
      
      assert {:ok, _msg2} = result2
      
      updated_content2 = File.read!(full_path)
      expected2 = "Line 1\nModified Line 2\n"
      
      assert updated_content2 == expected2
      assert String.ends_with?(updated_content2, "\n")
    end

    test "editing file without trailing newline", %{project: project} do
      # File content without trailing newline (edge case)
      content = "Line 1\nLine 2\nLine 3"
      
      mock_source_file(project, "no_trailing_newline.txt", content)
      full_path = Path.join(project.source_root, "no_trailing_newline.txt")
      
      # Replace middle line in file without trailing newline
      args = %{
        "path" => "no_trailing_newline.txt",
        "old_string" => "Line 2",
        "new_string" => "Modified Line 2"
      }
      
      result = AI.Tools.File.Edit.call(args)
      
      assert {:ok, msg} = result
      assert msg =~ "was modified successfully using exact matching"
      
      # Verify the edit worked and no trailing newline is preserved
      updated_content = File.read!(full_path)
      expected = "Line 1\nModified Line 2\nLine 3"
      
      assert updated_content == expected
      refute String.ends_with?(updated_content, "\n")
      
      # Test removing the last line (without newline)
      args2 = %{
        "path" => "no_trailing_newline.txt",
        "old_string" => "\nLine 3",
        "new_string" => ""
      }
      
      result2 = AI.Tools.File.Edit.call(args2)
      
      assert {:ok, _msg2} = result2
      
      updated_content2 = File.read!(full_path)
      expected2 = "Line 1\nModified Line 2"
      
      assert updated_content2 == expected2
      refute String.ends_with?(updated_content2, "\n")
    end
  end

  describe "error handling and validation" do
    test "safety check for overly long strings", %{project: project} do
      mock_source_file(project, "test.md", "short content")

      long_string = String.duplicate("a", 6000)

      args = %{
        "path" => "test.md",
        "old_string" => long_string,
        "new_string" => "replacement"
      }

      result = AI.Tools.File.Edit.call(args)

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

      result = AI.Tools.File.Edit.call(args)

      assert {:error, msg} = result
      assert msg =~ "File nonexistent.txt does not exist"
      assert msg =~ "Use file_manage_tool to create new files first"
    end

    test "attempting to find non-existent text in empty file", %{project: project} do
      # Create an empty file
      mock_source_file(project, "empty.txt", "")

      args = %{
        "path" => "empty.txt",
        "old_string" => "some text",
        "new_string" => "replacement"
      }

      result = AI.Tools.File.Edit.call(args)

      assert {:error, msg} = result
      assert msg =~ "Could not find the specified text"
    end

    test "uniqueness validation: multiple matches in file", %{project: project} do
      content = """
      function test() {
        return "test";
      }
      
      function another() {
        return "test";
      }
      """
      
      mock_source_file(project, "duplicate.js", content)

      # Try to replace "test" - this should fail due to multiple matches
      args = %{
        "path" => "duplicate.js",
        "old_string" => "test",
        "new_string" => "production"
      }

      result = AI.Tools.File.Edit.call(args)

      assert {:error, msg} = result
      assert msg =~ "Found multiple matches for the specified text"
      assert msg =~ "Please include more context to make old_string unique"
    end

    test "uniqueness validation: single match works fine", %{project: project} do
      content = """
      function test() {
        return "test value";
      }
      
      function another() {
        return "different value";
      }
      """
      
      mock_source_file(project, "unique.js", content)

      # Replace unique text - this should work
      args = %{
        "path" => "unique.js",
        "old_string" => "different value",
        "new_string" => "new value"
      }

      result = AI.Tools.File.Edit.call(args)

      assert {:ok, msg} = result
      assert msg =~ "was modified successfully"
      
      # Verify the change
      full_path = Path.join(project.source_root, "unique.js")
      updated_content = File.read!(full_path)
      assert updated_content =~ "new value"
      refute updated_content =~ "different value"
    end

    test "uniqueness validation: making old_string more specific resolves conflict", %{project: project} do
      content = """
      function test() {
        return "test";
      }
      
      function another() {
        return "test";
      }
      """
      
      mock_source_file(project, "specific.js", content)

      # Use more specific context to make it unique
      args = %{
        "path" => "specific.js",
        "old_string" => "function test() {\n  return \"test\";",
        "new_string" => "function test() {\n  return \"production\";"
      }

      result = AI.Tools.File.Edit.call(args)

      assert {:ok, msg} = result
      assert msg =~ "was modified successfully"
      
      # Verify only the first occurrence was changed
      full_path = Path.join(project.source_root, "specific.js")
      updated_content = File.read!(full_path)
      
      # Should contain one "production" and still have "test" in function names and second return
      production_count = updated_content |> String.split("production") |> length() |> Kernel.-(1)
      test_count = updated_content |> String.split("test") |> length() |> Kernel.-(1)
      
      assert production_count == 1
      # Should have 2 remaining: "test" in function name and "test" in second return statement  
      assert test_count == 2
    end

    test "empty old_string validation: fails during read_args", %{project: project} do
      # Test with existing file
      content = "Some existing content"
      mock_source_file(project, "existing.txt", content)

      args = %{
        "path" => "existing.txt",
        "old_string" => "",
        "new_string" => "New content"
      }

      # Empty old_string should be caught by read_args validation
      result = AI.Tools.File.Edit.read_args(args)

      assert {:error, :missing_argument, "old_string"} = result
      
      # Verify file was not changed when we call the full tool
      assert {:error, :missing_argument, "old_string"} = AI.Tools.File.Edit.call(args)
      full_path = Path.join(project.source_root, "existing.txt")
      unchanged_content = File.read!(full_path)
      assert unchanged_content == content
    end

    test "non-existent file error", %{project: project} do
      # File doesn't exist
      refute File.exists?(Path.join(project.source_root, "new.txt"))

      args = %{
        "path" => "new.txt",
        "old_string" => "some text",
        "new_string" => "New file content"
      }

      result = AI.Tools.File.Edit.call(args)

      assert {:error, msg} = result
      assert msg =~ "File new.txt does not exist"
      assert msg =~ "Use file_manage_tool to create new files first"
    end
  end
end
