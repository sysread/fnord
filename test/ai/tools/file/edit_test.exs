defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("edit-test")
    File.mkdir_p!(project.source_root)

    {:ok, project: project}
  end

  describe "async?/0" do
    test "positive path" do
      assert Edit.async?() == true
    end
  end

  describe "is_available?/0" do
    test "positive path" do
      assert Edit.is_available?() == true
    end
  end

  describe "read_args/1" do
    test "positive path" do
      args = %{"file" => "test.txt", "find" => "old", "replacement" => "new"}
      assert {:ok, ^args} = Edit.read_args(args)
    end
  end

  describe "ui_note_on_request/1" do
    test "positive path" do
      args = %{"file" => "test.txt", "find" => "old code", "replacement" => "new code"}

      {title, body} = Edit.ui_note_on_request(args)

      assert title == "Preparing file changes"
      assert body =~ "File: test.txt"
      assert body =~ "Replacing:"
      assert body =~ "old code"
      assert body =~ "With:"
      assert body =~ "new code"
    end
  end

  describe "ui_note_on_result/2" do
    test "positive path" do
      args = %{"file" => "test.txt"}
      result = "some diff output"

      {title, file} = Edit.ui_note_on_result(args, result)

      assert title == "File edited successfully"
      assert file == "test.txt"
    end
  end

  describe "spec/0" do
    test "positive path" do
      spec = Edit.spec()

      assert spec.type == "function"
      assert spec.function.name == "file_edit_tool"
      assert is_binary(spec.function.description)

      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == ["file", "find", "replacement"]

      assert Map.has_key?(params.properties, :file)
      assert Map.has_key?(params.properties, :find)
      assert Map.has_key?(params.properties, :replacement)
    end
  end

  describe "call/1" do
    test "positive path", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      original_content = "line 1\nold content\nline 3"
      File.write!(test_file, original_content)

      # Mock the AI agents to avoid network calls
      :meck.new(AI.Agent.Code.HunkFinder, [:passthrough])
      :meck.new(AI.Agent.Code.PatchMaker, [:passthrough])
      :meck.new(Hunk, [:passthrough])

      test_hunk = %Hunk{
        file: test_file,
        start_line: 2,
        end_line: 2,
        contents: "old content",
        hash: "test_hash"
      }

      adjusted_replacement = "new content"

      :meck.expect(AI.Agent.Code.HunkFinder, :get_response, fn _args ->
        {:ok, test_hunk}
      end)

      :meck.expect(AI.Agent.Code.PatchMaker, :get_response, fn _args ->
        {:ok, adjusted_replacement}
      end)

      :meck.expect(Hunk, :replace_in_file, fn _hunk, _replacement ->
        :ok
      end)

      args = %{
        "file" => "test.txt",
        "find" => "old content",
        "replacement" => "new content"
      }

      assert {:ok, diff} = Edit.call(args)
      assert is_binary(diff)

      :meck.unload(AI.Agent.Code.HunkFinder)
      :meck.unload(AI.Agent.Code.PatchMaker)
      :meck.unload(Hunk)
    end

    test "fails when file argument is missing" do
      args = %{"find" => "old", "replacement" => "new"}

      assert {:error, :missing_argument, "file"} = Edit.call(args)
    end

    test "fails when find argument is missing" do
      args = %{"file" => "test.txt", "replacement" => "new"}

      assert {:error, :missing_argument, "find"} = Edit.call(args)
    end

    test "fails when replacement argument is missing" do
      args = %{"file" => "test.txt", "find" => "old"}

      assert {:error, :missing_argument, "replacement"} = Edit.call(args)
    end

    test "fails when hunk finder fails", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "some content")

      # Mock HunkFinder to return error
      :meck.new(AI.Agent.Code.HunkFinder, [:passthrough])

      :meck.expect(AI.Agent.Code.HunkFinder, :get_response, fn _args ->
        {:error, "Could not find matching section"}
      end)

      args = %{
        "file" => "test.txt",
        "find" => "nonexistent",
        "replacement" => "new content"
      }

      assert {:error, "Could not find matching section"} = Edit.call(args)

      :meck.unload(AI.Agent.Code.HunkFinder)
    end

    test "fails when patch maker fails", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "old content")

      # Mock agents
      :meck.new(AI.Agent.Code.HunkFinder, [:passthrough])
      :meck.new(AI.Agent.Code.PatchMaker, [:passthrough])

      test_hunk = %Hunk{
        file: test_file,
        start_line: 1,
        end_line: 1,
        contents: "old content",
        hash: "test_hash"
      }

      :meck.expect(AI.Agent.Code.HunkFinder, :get_response, fn _args ->
        {:ok, test_hunk}
      end)

      :meck.expect(AI.Agent.Code.PatchMaker, :get_response, fn _args ->
        {:error, "Failed to adjust replacement"}
      end)

      args = %{
        "file" => "test.txt",
        "find" => "old content",
        "replacement" => "new content"
      }

      assert {:error, "Failed to adjust replacement"} = Edit.call(args)

      :meck.unload(AI.Agent.Code.HunkFinder)
      :meck.unload(AI.Agent.Code.PatchMaker)
    end

    test "fails when file replacement fails", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "old content")

      # Mock agents and Hunk
      :meck.new(AI.Agent.Code.HunkFinder, [:passthrough])
      :meck.new(AI.Agent.Code.PatchMaker, [:passthrough])
      :meck.new(Hunk, [:passthrough])

      test_hunk = %Hunk{
        file: test_file,
        start_line: 1,
        end_line: 1,
        contents: "old content",
        hash: "test_hash"
      }

      :meck.expect(AI.Agent.Code.HunkFinder, :get_response, fn _args ->
        {:ok, test_hunk}
      end)

      :meck.expect(AI.Agent.Code.PatchMaker, :get_response, fn _args ->
        {:ok, "new content"}
      end)

      :meck.expect(Hunk, :replace_in_file, fn _hunk, _replacement ->
        {:error, :file_changed}
      end)

      args = %{
        "file" => "test.txt",
        "find" => "old content",
        "replacement" => "new content"
      }

      assert {:error, :file_changed} = Edit.call(args)

      :meck.unload(AI.Agent.Code.HunkFinder)
      :meck.unload(AI.Agent.Code.PatchMaker)
      :meck.unload(Hunk)
    end
  end
end
