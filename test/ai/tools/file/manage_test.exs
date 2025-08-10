defmodule AI.Tools.File.ManageTest do
  use Fnord.TestCase

  alias AI.Tools.File.Manage

  setup do
    project = mock_project("test-project")
    File.mkdir_p!(project.source_root)
    {:ok, project: project}
  end

  describe "file create" do
    test "successfully creates a new file", %{project: project} do
      path = "foo/bar.txt"
      abs_path = Path.join(project.source_root, path)
      refute File.exists?(abs_path)

      args = %{"operation" => "create", "path" => path}
      assert {:ok, "Created file: foo/bar.txt"} = Manage.call(args)
      assert File.exists?(abs_path)
      assert File.read!(abs_path) == ""
    end

    test "successfully creates a new file with initial contents", %{project: project} do
      path = "foo/bar.txt"
      abs_path = Path.join(project.source_root, path)
      refute File.exists?(abs_path)

      args = %{"operation" => "create", "path" => path, "file_content" => "Hello, world!"}
      assert {:ok, "Created file: foo/bar.txt"} = Manage.call(args)
      assert File.exists?(abs_path)
      assert File.read!(abs_path) == "Hello, world!"
    end

    test "refuses to create if file exists", %{project: project} do
      path = "foo/existing.txt"
      abs_path = Path.join(project.source_root, path)
      File.mkdir_p!(Path.dirname(abs_path))
      File.write!(abs_path, "stuff")

      args = %{"operation" => "create", "path" => path}
      assert {:error, reason} = Manage.call(args)
      assert reason =~ "already exists"
    end

    test "refuses to create outside project root" do
      args = %{"operation" => "create", "path" => "../evil.txt"}
      assert {:error, reason} = Manage.call(args)
      assert reason =~ "escapes project root"
    end
  end

  describe "replace" do
    test "successfully overwrites an existing file", %{project: project} do
      path = "bar.txt"
      abs_path = Path.join(project.source_root, path)
      refute File.exists?(abs_path)

      File.write!(abs_path, "Old content")
      assert File.read!(abs_path) == "Old content"

      args = %{"operation" => "replace", "path" => path, "file_content" => "New content"}
      assert {:ok, "Replaced file contents: bar.txt"} = Manage.call(args)
      assert File.exists?(abs_path)
      assert File.read!(abs_path) == "New content"
    end

    test "refuses to overwrite a non-existent file", %{project: project} do
      path = "foo/bar.txt"
      abs_path = Path.join(project.source_root, path)
      refute File.exists?(abs_path)

      args = %{"operation" => "replace", "path" => path, "file_content" => "New content"}
      assert {:error, reason} = Manage.call(args)
      assert reason =~ "does not exist"
    end
  end

  describe "file delete" do
    test "deletes an existing file", %{project: project} do
      path = "deleteme.txt"
      abs_path = Path.join(project.source_root, path)
      File.write!(abs_path, "data")

      args = %{"operation" => "delete", "path" => path}
      assert {:ok, "Deleted file: deleteme.txt"} = Manage.call(args)
      refute File.exists?(abs_path)
    end

    test "complains if file does not exist" do
      args = %{"operation" => "delete", "path" => "ghost.txt"}
      assert {:error, reason} = Manage.call(args)
      assert reason =~ "does not exist"
    end

    test "refuses to delete outside project root" do
      args = %{"operation" => "delete", "path" => "../outside.txt"}
      assert {:error, reason} = Manage.call(args)
      assert reason =~ "escapes project root"
    end
  end

  describe "file move" do
    test "moves file within project", %{project: project} do
      src = "move_from.txt"
      dest = "dir/move_to.txt"
      abs_src = Path.join(project.source_root, src)
      abs_dest = Path.join(project.source_root, dest)
      File.write!(abs_src, "moving data")

      args = %{"operation" => "move", "path" => src, "destination_path" => dest}
      assert {:ok, msg} = Manage.call(args)
      assert msg =~ "Moved move_from.txt -> dir/move_to.txt"
      refute File.exists?(abs_src)
      assert File.exists?(abs_dest)
      assert File.read!(abs_dest) == "moving data"
    end

    test "complains if destination already exists", %{project: project} do
      src = "a.txt"
      dest = "b.txt"
      abs_src = Path.join(project.source_root, src)
      abs_dest = Path.join(project.source_root, dest)
      File.write!(abs_src, "A")
      File.write!(abs_dest, "B")

      args = %{"operation" => "move", "path" => src, "destination_path" => dest}
      assert {:error, reason} = Manage.call(args)
      assert reason =~ "Destination path already exists"
      assert File.read!(abs_dest) == "B"
    end

    test "complains if source does not exist" do
      args = %{"operation" => "move", "path" => "foo.txt", "destination_path" => "bar.txt"}
      assert {:error, reason} = Manage.call(args)
      assert reason =~ "Source path does not exist"
    end

    test "refuses to move to path outside project root", %{project: project} do
      src = "shouldnotmove.txt"
      File.write!(Path.join(project.source_root, src), "nope")
      args = %{"operation" => "move", "path" => src, "destination_path" => "../outside.txt"}
      assert {:error, reason} = Manage.call(args)
      assert reason =~ "escapes project root"
    end

    test "refuses to move from path outside project root" do
      args = %{
        "operation" => "move",
        "path" => "../outside.txt",
        "destination_path" => "inside.txt"
      }

      assert {:error, reason} = Manage.call(args)
      assert reason =~ "escapes project root"
    end
  end

  describe "read_args/1" do
    test "returns error on missing operation" do
      assert {:error, :missing_argument, "operation"} = Manage.read_args(%{})
      assert {:error, :missing_argument, "operation"} = Manage.read_args(%{"foo" => "bar"})
    end

    test "returns error on invalid operation" do
      assert {:error, :invalid_argument, "operation"} =
               Manage.read_args(%{"operation" => "poke", "path" => "f"})
    end

    test "returns error on missing path" do
      assert {:error, :missing_argument, "path"} = Manage.read_args(%{"operation" => "create"})
    end

    test "returns error on missing destination for move" do
      assert {:error, :missing_argument, "destination_path"} =
               Manage.read_args(%{"operation" => "move", "path" => "f"})
    end

    test "returns ok with valid data" do
      args = %{"operation" => "move", "path" => "a.txt", "destination_path" => "b.txt"}

      assert {:ok, %{"operation" => "move", "path" => "a.txt", "destination_path" => "b.txt"}} =
               Manage.read_args(args)
    end

    test "read_args accepts replace with path and file_content" do
      args = %{"operation" => "replace", "path" => "f.txt", "file_content" => "x"}

      assert {:ok, %{"operation" => "replace", "path" => "f.txt", "file_content" => "x"}} =
               AI.Tools.File.Manage.read_args(args)
    end
  end
end
