defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("edit-test")
    File.mkdir_p!(project.source_root)

    # Reset backup server state for clean tests
    BackupFileServer.reset()

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
    test "positive path with JSON-encoded backup info" do
      args = %{"file" => "test.txt"}

      result =
        Jason.encode!(%{
          diff: "some diff output",
          backup_file: "/path/to/test.txt.0.0.bak",
          backup_files: ["/path/to/test.txt.0.0.bak"]
        })

      stderr_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {title, message} = Edit.ui_note_on_result(args, result)

          assert title == "File edited successfully"
          assert message == "test.txt (backup: test.txt.0.0.bak)"
        end)

      assert stderr_output == "some diff output"
    end

    test "fallback for non-JSON string result" do
      args = %{"file" => "test.txt"}
      result = "some diff output"

      stderr_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {title, file} = Edit.ui_note_on_result(args, result)

          assert title == "File edited successfully"
          assert file == "test.txt"
        end)

      assert stderr_output == "some diff output"
    end

    test "fallback for malformed JSON" do
      args = %{"file" => "test.txt"}
      result = "{invalid json"

      stderr_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {title, file} = Edit.ui_note_on_result(args, result)

          assert title == "File edited successfully"
          assert file == "test.txt"
        end)

      assert stderr_output == "{invalid json"
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
    test "positive path creates backup and returns expected structure", %{project: project} do
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

      assert {:ok, result} = Edit.call(args)
      assert Map.has_key?(result, :diff)
      assert Map.has_key?(result, :backup_file)
      assert Map.has_key?(result, :backup_files)
      assert is_binary(result.diff)
      assert is_binary(result.backup_file)
      assert is_list(result.backup_files)

      # Verify backup file was created with correct naming
      expected_backup = "#{test_file}.0.0.bak"
      assert result.backup_file == expected_backup
      assert File.exists?(expected_backup)
      assert File.read!(expected_backup) == original_content

      :meck.unload(AI.Agent.Code.HunkFinder)
      :meck.unload(AI.Agent.Code.PatchMaker)
      :meck.unload(Hunk)
    end

    test "multiple edits of same file increment change counter", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      original_content = "content to edit"
      File.write!(test_file, original_content)

      # Mock the AI agents
      :meck.new(AI.Agent.Code.HunkFinder, [:passthrough])
      :meck.new(AI.Agent.Code.PatchMaker, [:passthrough])
      :meck.new(Hunk, [:passthrough])

      test_hunk = %Hunk{
        file: test_file,
        start_line: 1,
        end_line: 1,
        contents: "content to edit",
        hash: "test_hash"
      }

      :meck.expect(AI.Agent.Code.HunkFinder, :get_response, fn _args ->
        {:ok, test_hunk}
      end)

      :meck.expect(AI.Agent.Code.PatchMaker, :get_response, fn _args ->
        {:ok, "edited content"}
      end)

      :meck.expect(Hunk, :replace_in_file, fn _hunk, _replacement ->
        :ok
      end)

      args = %{
        "file" => "test.txt",
        "find" => "content",
        "replacement" => "edited content"
      }

      # First edit
      assert {:ok, result1} = Edit.call(args)
      expected_backup1 = "#{test_file}.0.0.bak"
      assert result1.backup_file == expected_backup1
      assert File.exists?(expected_backup1)

      # Second edit
      assert {:ok, result2} = Edit.call(args)
      expected_backup2 = "#{test_file}.0.1.bak"
      assert result2.backup_file == expected_backup2
      assert File.exists?(expected_backup2)

      # Third edit
      assert {:ok, result3} = Edit.call(args)
      expected_backup3 = "#{test_file}.0.2.bak"
      assert result3.backup_file == expected_backup3
      assert File.exists?(expected_backup3)

      # Verify all backups are tracked
      assert length(result3.backup_files) == 3

      :meck.unload(AI.Agent.Code.HunkFinder)
      :meck.unload(AI.Agent.Code.PatchMaker)
      :meck.unload(Hunk)
    end

    test "global counter increments when existing backup found", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      original_content = "content to edit"
      File.write!(test_file, original_content)

      # Create existing backup file from "previous session"
      existing_backup = "#{test_file}.0.0.bak"
      File.write!(existing_backup, "old backup content")

      # Mock the AI agents
      :meck.new(AI.Agent.Code.HunkFinder, [:passthrough])
      :meck.new(AI.Agent.Code.PatchMaker, [:passthrough])
      :meck.new(Hunk, [:passthrough])

      test_hunk = %Hunk{
        file: test_file,
        start_line: 1,
        end_line: 1,
        contents: "content to edit",
        hash: "test_hash"
      }

      :meck.expect(AI.Agent.Code.HunkFinder, :get_response, fn _args ->
        {:ok, test_hunk}
      end)

      :meck.expect(AI.Agent.Code.PatchMaker, :get_response, fn _args ->
        {:ok, "edited content"}
      end)

      :meck.expect(Hunk, :replace_in_file, fn _hunk, _replacement ->
        :ok
      end)

      args = %{
        "file" => "test.txt",
        "find" => "content",
        "replacement" => "edited content"
      }

      assert {:ok, result} = Edit.call(args)

      # Should use global counter 1 since 0 already exists
      expected_backup = "#{test_file}.1.0.bak"
      assert result.backup_file == expected_backup
      assert File.exists?(expected_backup)
      assert File.read!(expected_backup) == original_content

      # Original backup should still exist unchanged
      assert File.exists?(existing_backup)
      assert File.read!(existing_backup) == "old backup content"

      :meck.unload(AI.Agent.Code.HunkFinder)
      :meck.unload(AI.Agent.Code.PatchMaker)
      :meck.unload(Hunk)
    end

    test "different files get independent counters", %{project: project} do
      # Create two test files
      test_file1 = Path.join(project.source_root, "file1.txt")
      test_file2 = Path.join(project.source_root, "file2.txt")
      File.write!(test_file1, "content 1")
      File.write!(test_file2, "content 2")

      # Mock the AI agents
      :meck.new(AI.Agent.Code.HunkFinder, [:passthrough])
      :meck.new(AI.Agent.Code.PatchMaker, [:passthrough])
      :meck.new(Hunk, [:passthrough])

      :meck.expect(AI.Agent.Code.HunkFinder, :get_response, fn %{file: file} ->
        test_hunk = %Hunk{
          file: file,
          start_line: 1,
          end_line: 1,
          contents: if(String.ends_with?(file, "file1.txt"), do: "content 1", else: "content 2"),
          hash: "test_hash"
        }

        {:ok, test_hunk}
      end)

      :meck.expect(AI.Agent.Code.PatchMaker, :get_response, fn _args ->
        {:ok, "edited content"}
      end)

      :meck.expect(Hunk, :replace_in_file, fn _hunk, _replacement ->
        :ok
      end)

      # Edit file1
      args1 = %{"file" => "file1.txt", "find" => "content", "replacement" => "edited"}
      assert {:ok, result1} = Edit.call(args1)
      expected_backup1 = "#{test_file1}.0.0.bak"
      assert result1.backup_file == expected_backup1

      # Edit file2
      args2 = %{"file" => "file2.txt", "find" => "content", "replacement" => "edited"}
      assert {:ok, result2} = Edit.call(args2)
      expected_backup2 = "#{test_file2}.0.0.bak"
      assert result2.backup_file == expected_backup2

      # Both should have global counter 0, change counter 0
      assert File.exists?(expected_backup1)
      assert File.exists?(expected_backup2)
      assert File.read!(expected_backup1) == "content 1"
      assert File.read!(expected_backup2) == "content 2"

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

    test "fails when backup creation fails", %{project: _project} do
      # Mock backup server to return error
      :meck.new(BackupFileServer, [:passthrough])

      :meck.expect(BackupFileServer, :create_backup, fn _file ->
        {:error, :source_file_not_found}
      end)

      args = %{
        "file" => "nonexistent.txt",
        "find" => "content",
        "replacement" => "new content"
      }

      assert {:error, :source_file_not_found} = Edit.call(args)

      :meck.unload(BackupFileServer)
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
