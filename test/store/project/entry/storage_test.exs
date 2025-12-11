defmodule Store.Project.Entry.StorageTest do
  use Fnord.TestCase, async: false

  alias Store.Project.Entry
  alias Store.Project.Entry.Storage

  setup do
    {:ok, project: mock_project("test_proj")}
  end

  describe "create and exists?/1" do
    test "storage does not exist until created", %{project: project} do
      # Prepare source file and entry
      path = mock_source_file(project, "a.txt", "hello world")
      entry = Entry.new_from_file_path(project, path)

      refute Storage.exists?(entry)
      :ok = Storage.create(entry)
      assert Storage.exists?(entry)
    end
  end

  describe "save and read/1" do
    test "writes and reads entry data correctly", %{project: project} do
      # Prepare source file and entry
      path = mock_source_file(project, "b.txt", "content here")
      entry = Entry.new_from_file_path(project, path)

      # Dummy data
      summary = "this is a summary"
      outline = "- first item\n- second item"
      embeddings = [0.1, 0.2, 0.3]

      # Save via Storage
      :ok = Storage.save(entry, summary, outline, embeddings)

      # Read via Storage
      assert {:ok, info} = Storage.read(entry)
      assert info["file"] == entry.file
      assert info["summary"] == summary
      assert info["outline"] == outline
      assert info["embeddings"] == embeddings
    end
  end

  describe "incomplete and stale checks" do
    test "storage is incomplete and stale before save", %{project: project} do
      path = mock_source_file(project, "c.txt", "zzz")
      entry = Entry.new_from_file_path(project, path)

      :ok = Storage.create(entry)
      assert Storage.is_incomplete?(entry)
      assert Storage.is_stale?(entry)
    end

    test "storage is complete and not stale after save", %{project: project} do
      path = mock_source_file(project, "d.txt", "yyy")
      entry = Entry.new_from_file_path(project, path)

      # Save creates and writes all data
      :ok = Storage.save(entry, "sum", "outline", [1.0])

      refute Storage.is_incomplete?(entry)
      refute Storage.is_stale?(entry)
    end
  end
end
