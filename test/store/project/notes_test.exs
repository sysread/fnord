defmodule Store.Project.NotesTest do
  use Fnord.TestCase

  alias Store.Project.Notes

  describe "reset/1" do
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

  describe "write/2" do
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

  describe "read/1" do
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
end
