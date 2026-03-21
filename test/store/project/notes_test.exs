defmodule Store.Project.NotesTest do
  use Fnord.TestCase, async: false

  alias Store.Project.Notes

  describe "reset/0 and reset/1" do
    setup do
      project = mock_project("notes_reset_test")
      # ensure store_path & notes_dir exist so we can create files under them
      File.mkdir_p!(project.store_path)
      {:ok, project: project}
    end

    test "removes new and old notes if they exist", %{project: project} do
      path = Path.join(project.store_path, "notes.md")

      File.write!(path, "new notes content")
      assert File.exists?(path)

      :ok = Notes.reset()
      refute File.exists?(path)
    end

    test "ok when files do not exist" do
      {:ok, notes_file} = Notes.file_path()
      :ok = Notes.reset()
      refute File.exists?(notes_file)
    end
  end

  describe "write/1 and write/2" do
    setup do
      project = mock_project("notes_write_test")
      File.mkdir_p!(project.store_path)
      {:ok, project: project}
    end

    test "writes content to notes.md", %{project: project} do
      content = "hello, this is some notes"
      :ok = Notes.write(content)

      path = Path.join(project.store_path, "notes.md")
      assert File.read!(path) == content
    end

    test "returns error tuple when File.write fails", %{project: project} do
      # make the store_path unwritable
      File.chmod!(project.store_path, 0o500)
      assert {:error, _reason} = Notes.write("will fail")
      # restore permissions so cleanup can proceed
      File.chmod!(project.store_path, 0o700)
    end
  end

  describe "read/0 and read/1" do
    setup do
      project = mock_project("notes_read_test")
      File.mkdir_p!(project.store_path)
      {:ok, project: project}
    end

    test "reads notes from new notes.md", %{project: project} do
      path = Path.join(project.store_path, "notes.md")
      File.write!(path, "new notes content")
      assert {:ok, "new notes content"} = Notes.read()
    end

    test "returns error if no notes found" do
      assert {:error, :no_notes} = Notes.read()
    end
  end

  describe "by-project overloads" do
    setup do
      project = mock_project("notes_by_project_test")
      other_project = mock_project("notes_by_project_other_test")

      File.mkdir_p!(project.store_path)
      File.mkdir_p!(other_project.store_path)

      {:ok, project: project, other_project: other_project}
    end

    test "read/1 reads notes for the named project", %{
      project: project,
      other_project: other_project
    } do
      File.write!(Path.join(project.store_path, "notes.md"), "project notes content")
      File.write!(Path.join(other_project.store_path, "notes.md"), "other project notes content")

      assert {:ok, "project notes content"} = Notes.read(project.name)
    end

    test "write/2 writes content to the named project's notes file", %{
      project: project,
      other_project: other_project
    } do
      content = "hello from named project write"
      :ok = Notes.write(project.name, content)

      assert File.read!(Path.join(project.store_path, "notes.md")) == content
      refute File.exists?(Path.join(other_project.store_path, "notes.md"))
    end

    test "file_path/1 returns the named project's notes path", %{project: project} do
      expected = Path.join(project.store_path, "notes.md")
      assert {:ok, actual} = Notes.file_path(project.name)
      assert actual == expected
    end

    test "file_path/1 returns the project's notes path when given a project struct", %{
      project: project
    } do
      expected = Path.join(project.store_path, "notes.md")
      assert {:ok, actual} = Notes.file_path(project)
      assert actual == expected
    end
  end
end
