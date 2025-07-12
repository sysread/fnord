defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("edit-proj")
    File.mkdir_p!(project.source_root)
    path = mock_source_file(project, "test_file.txt", "aaa\nbbb\nccc\n\n")
    {:ok, project: project, path: path}
  end

  describe "positive path" do
    test "basic case", %{path: path} do
      args = %{"path" => path, "start_line" => 2, "end_line" => 3, "replacement" => "ccc\nbbb\n"}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.0."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.read!(path) == "aaa\nccc\nbbb\n\n"
      assert File.exists?(path <> ".bak.0")
      assert File.read!(path <> ".bak.0") == "aaa\nbbb\nccc\n\n"
    end

    test "multiple backups are created for multiple edits", %{path: path} do
      args = %{"path" => path, "start_line" => 2, "end_line" => 3, "replacement" => "ccc\nbbb\n"}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.0."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.exists?(path <> ".bak.0")

      # Make another edit
      args = %{"path" => path, "start_line" => 1, "end_line" => 1, "replacement" => "zzz\n"}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.1."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.exists?(path <> ".bak.1")
    end

    test "edit at beginning of file", %{path: path} do
      args = %{"path" => path, "start_line" => 1, "end_line" => 1, "replacement" => "zzz\n"}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.0."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.read!(path) == "zzz\nbbb\nccc\n\n"
      assert File.exists?(path <> ".bak.0")
      assert File.read!(path <> ".bak.0") == "aaa\nbbb\nccc\n\n"
    end

    test "edit at end of file", %{path: path} do
      args = %{"path" => path, "start_line" => 4, "end_line" => 4, "replacement" => "zzz\n"}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.0."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.read!(path) == "aaa\nbbb\nccc\nzzz\n"
      assert File.exists?(path <> ".bak.0")
      assert File.read!(path <> ".bak.0") == "aaa\nbbb\nccc\n\n"
    end

    test "edit to remove lines", %{path: path} do
      args = %{"path" => path, "start_line" => 2, "end_line" => 2, "replacement" => ""}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.0."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.read!(path) == "aaa\nccc\n\n"
      assert File.exists?(path <> ".bak.0")
      assert File.read!(path <> ".bak.0") == "aaa\nbbb\nccc\n\n"
    end

    test "edit to insert line", %{path: path} do
      args = %{"path" => path, "start_line" => 2, "end_line" => 2, "replacement" => "zzz\nbbb\n"}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.0."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.read!(path) == "aaa\nzzz\nbbb\nccc\n\n"
      assert File.exists?(path <> ".bak.0")
      assert File.read!(path <> ".bak.0") == "aaa\nbbb\nccc\n\n"
    end

    test "remove newline at end of file", %{path: path} do
      args = %{"path" => path, "start_line" => 4, "end_line" => 4, "replacement" => ""}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.0."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.read!(path) == "aaa\nbbb\nccc\n"
      assert File.exists?(path <> ".bak.0")
      assert File.read!(path <> ".bak.0") == "aaa\nbbb\nccc\n\n"
    end

    test "remove newline at beginning of file", %{path: path} do
      File.write!(path, "\n\naaa\nbbb\nccc\n")
      args = %{"path" => path, "start_line" => 1, "end_line" => 1, "replacement" => ""}
      msg = "#{path} was modified successfully. A backup was created at #{path}.bak.0."
      assert {:ok, ^msg} = Edit.call(args)
      assert File.read!(path) == "\naaa\nbbb\nccc\n"
      assert File.exists?(path <> ".bak.0")
      assert File.read!(path <> ".bak.0") == "\n\naaa\nbbb\nccc\n"
    end
  end

  describe "negative path" do
    test "file does not exist", %{project: project} do
      bad_path = Path.join(project.source_root, "not_there.txt")
      args = %{"path" => bad_path, "start_line" => 1, "end_line" => 1, "replacement" => ""}
      assert {:error, msg} = Edit.call(args)
      assert msg =~ "not_there.txt"
      assert msg =~ "not found"
    end

    test "start_line is less than 1", %{path: path} do
      args = %{"path" => path, "start_line" => 0, "end_line" => 1, "replacement" => ""}
      assert {:error, msg} = Edit.call(args)
      assert msg =~ "Start line must be greater than or equal to 1"
    end

    test "start_line exceeds number of lines", %{path: path} do
      content = File.read!(path)
      line_count = length(String.split(content, "\n", trim: false))

      args = %{
        "path" => path,
        "start_line" => line_count + 1,
        "end_line" => line_count + 1,
        "replacement" => ""
      }

      assert {:error, msg} = Edit.call(args)
      assert msg =~ "Start line exceeds the number of lines"
    end

    test "end_line less than start_line", %{path: path} do
      args = %{"path" => path, "start_line" => 3, "end_line" => 2, "replacement" => ""}
      assert {:error, msg} = Edit.call(args)
      assert msg =~ "End line must be greater than or equal to start line"
    end

    test "end_line exceeds number of lines", %{path: path} do
      content = File.read!(path)
      line_count = length(String.split(content, "\n", trim: false))

      args = %{
        "path" => path,
        "start_line" => 1,
        "end_line" => line_count + 1,
        "replacement" => ""
      }

      assert {:error, msg} = Edit.call(args)
      assert msg =~ "End line exceeds the number of lines"
    end

    test "path is outside source root" do
      # Pick an absolute path that's definitely outside project root
      abs_path = "/tmp/not_allowed.txt"
      args = %{"path" => abs_path, "start_line" => 1, "end_line" => 1, "replacement" => ""}
      assert {:error, msg} = Edit.call(args)
      assert msg =~ "Failed to edit file"
      assert msg =~ "not within project root"
    end

    test "backup file cannot be created", %{path: path} do
      # Simulate backup failure by making the file read-only (or override backup_file/2 in a mock if using Mox)
      # Here, forcibly remove write permissions and try to back up (depends on system permissions)
      File.chmod!(path, 0o400)
      args = %{"path" => path, "start_line" => 1, "end_line" => 1, "replacement" => "oops\n"}
      result = Edit.call(args)
      # Restore permissions for cleanup
      File.chmod!(path, 0o644)
      assert match?({:error, _}, result)
    end

    test "file cannot be written after edit", %{path: path} do
      # Simulate temp file can't be written (will be system dependent)
      # If Briefly.create/0 fails, it'll be covered elsewhere; here, forcibly set file permissions after edit
      File.chmod!(path, 0o400)
      args = %{"path" => path, "start_line" => 1, "end_line" => 1, "replacement" => "foo\n"}
      result = Edit.call(args)
      File.chmod!(path, 0o644)
      assert match?({:error, _}, result)
    end
  end
end
