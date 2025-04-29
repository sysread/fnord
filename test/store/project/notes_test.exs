defmodule Store.Project.NotesTest do
  use Fnord.TestCase, async: true

  alias Store.Project.Notes
  alias Store.Project.Note

  describe "reset/1" do
    setup do
      project = mock_project("notes_reset_test")
      # ensure store_path & notes_dir exist so we can create files under them
      File.mkdir_p!(project.store_path)
      File.mkdir_p!(project.notes_dir)
      {:ok, project: project}
    end

    test "removes new and old notes if they exist", %{project: project} do
      new_path = Path.join(project.store_path, "notes.md")
      old_path = project.notes_dir

      File.write!(new_path, "new notes content")
      assert File.exists?(new_path)
      assert File.exists?(old_path)

      :ok = Notes.reset(project)

      refute File.exists?(new_path)
      refute File.exists?(old_path)
    end

    test "removes only new notes if only new exists", %{project: project} do
      old_path = project.notes_dir
      File.rm_rf!(old_path)

      new_path = Path.join(project.store_path, "notes.md")
      File.write!(new_path, "solo new content")
      assert File.exists?(new_path)
      refute File.exists?(old_path)

      :ok = Notes.reset(project)

      refute File.exists?(new_path)
      refute File.exists?(old_path)
    end

    test "ok when files do not exist", %{project: project} do
      :ok = Notes.reset(project)
      refute File.exists?(Path.join(project.store_path, "notes.md"))
      refute File.exists?(project.notes_dir)
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
      :ok = Notes.write(project, content)

      new_path = Path.join(project.store_path, "notes.md")
      assert File.read!(new_path) == content
    end

    test "returns error tuple when File.write fails", %{project: project} do
      # make the store_path unwritable
      File.chmod!(project.store_path, 0o500)
      assert {:error, _reason} = Notes.write(project, "will fail")
      # restore permissions so cleanup can proceed
      File.chmod!(project.store_path, 0o700)
    end
  end

  describe "read/1" do
    setup do
      project = mock_project("notes_read_test")
      File.mkdir_p!(project.store_path)
      File.mkdir_p!(project.notes_dir)
      {:ok, project: project}
    end

    test "reads notes from new notes.md", %{project: project} do
      path = Path.join(project.store_path, "notes.md")
      File.write!(path, "new notes content\n\n")
      assert {:ok, "new notes content"} = Notes.read(project)
    end

    test "reads notes from old structured notes", %{project: project} do
      note1 = Note.new(project, "001")
      {:ok, ^note1} = Note.write(note1, "{topic first {fact one}}")

      note2 = Note.new(project, "002")
      {:ok, ^note2} = Note.write(note2, "{topic second {fact two}}")

      {:ok, notes} = Notes.read(project)
      assert String.starts_with?(notes, "!!! These research notes are in an old, legacy format.")
      assert notes =~ "{topic first {fact one}}"
      assert notes =~ "{topic second {fact two}}"
    end

    test "returns error if no notes found", %{project: project} do
      # remove the legacy directory so read_old_notes/1 will error
      File.rm_rf!(project.notes_dir)

      assert {:error, :no_notes} = Notes.read(project)
    end

    test "returns header only when legacy notes dir is empty", %{project: project} do
      # ensure no new notes
      File.rm_rf!(Path.join(project.store_path, "notes.md"))
      # reset legacy dir to be empty
      File.rm_rf!(project.notes_dir)
      File.mkdir_p!(project.notes_dir)

      {:ok, notes} = Notes.read(project)

      expected =
        """
        !!! These research notes are in an old, legacy format.
        !!! They must be replaced with the new format.
        """
        |> String.trim()

      assert notes == expected
    end

    test "filters out invalid legacy notes", %{project: project} do
      # write one valid legacy note
      valid_note = Note.new(project, "001")
      {:ok, ^valid_note} = Note.write(valid_note, "{topic valid {fact ok}}")

      # create a bogus legacy subdirectory without a note.md file
      File.mkdir_p!(Path.join(project.notes_dir, "999"))

      {:ok, notes} = Notes.read(project)

      # should include only the valid note content
      assert notes =~ "{topic valid {fact ok}}"
      # should not accidentally include the bogus directory name
      refute notes =~ "999"
    end
  end
end
