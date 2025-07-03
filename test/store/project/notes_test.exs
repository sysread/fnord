defmodule Store.Project.NotesTest do
  use Fnord.TestCase

  alias Store.Project.Notes

  # Helper: derive mock project path and file paths
  defp notes_json_path() do
    with {:ok, file} <- Store.Project.Notes.file_path() do
      file
    end
  end

  defp notes_md_path() do
    with {:ok, file} <- Store.Project.Notes.file_path() do
      file |> String.replace(".json", ".md")
    end
  end

  setup do
    project = mock_project("notes_test")
    # ensure store_path & notes_dir exist so we can create files under them
    File.mkdir_p!(project.store_path)
    {:ok, project: project}
  end

  setup do
    File.write!(notes_md_path(), "legacy content")
    File.write!(notes_json_path(), ~s|{"title": "existing notes"}|)
    :ok
  end

  describe "reset/0" do
    test "removes both legacy and current files if present" do
      assert File.exists?(notes_md_path())
      assert File.exists?(notes_json_path())
      assert :ok = Notes.reset()
      refute File.exists?(notes_md_path())
      refute File.exists?(notes_json_path())
    end

    test "idempotence: does not error if files missing" do
      File.rm_rf!(notes_md_path())
      File.rm_rf!(notes_json_path())
      refute File.exists?(notes_md_path())
      refute File.exists?(notes_json_path())
      assert :ok = Notes.reset()
      assert :ok = Notes.reset()
    end
  end

  describe "write/1" do
    test "writes a map as notes.json" do
      notes_map = %{"title" => "My Notes", "items" => ["item1", "item2"]}
      assert :ok = Notes.write(notes_map)
      {:ok, file_content} = File.read(notes_json_path())
      {:ok, decoded} = Jason.decode(file_content)
      assert decoded == notes_map
    end

    test "writes binary JSON data directly" do
      json_binary = ~s|{"hello": "world"}|
      assert :ok = Notes.write(json_binary)
      {:ok, file_content} = File.read(notes_json_path())
      assert file_content == json_binary
    end
  end

  describe "read/0" do
    test "returns {:ok, notes_map} if notes.json exists" do
      notes_map = %{"name" => "test", "content" => "notes content"}
      File.write!(notes_json_path(), Jason.encode!(notes_map))
      assert {:ok, result} = Notes.read()
      assert result == notes_map
    end

    test "returns {:error, :no_notes} if notes.json is missing" do
      File.rm_rf!(notes_json_path())
      assert {:error, :no_notes} = Notes.read()
    end
  end

  describe "format/0" do
    test "outputs markdown for all sections" do
      notes = %{
        "Synopsis" => "Synopsis here.",
        "User" => "User persona.",
        "Layout" => "Project layout details.",
        "Applications & Components" => "Stuff here.",
        "Notes" => "The actual notes."
      }

      assert :ok = Notes.write(notes)
      {:ok, md} = Notes.format()

      Enum.each(Map.keys(notes), fn k ->
        assert String.contains?(md, "# #{k}")
        assert String.contains?(md, notes[k])
      end)
    end

    test "handles missing or empty sections" do
      Notes.write(%{})
      {:ok, md} = Notes.format()

      Enum.each(Notes.sections(), fn section ->
        assert String.contains?(md, "# #{section}")
        assert String.contains?(md, "_No notes available for this section._")
      end)
    end
  end

  describe "upgrade_to_json/0" do
    test "converts notes.md to notes.json and deletes legacy" do
      legacy_md = "# Synopsis\nhello synopsis\n# Notes\nmain notes here"
      File.write!(notes_md_path(), legacy_md)
      File.rm_rf!(notes_json_path())
      assert :ok = Notes.upgrade_to_json()
      refute File.exists?(notes_md_path())
      assert File.exists?(notes_json_path())
      {:ok, json_content} = File.read(notes_json_path())
      {:ok, decoded} = Jason.decode(json_content)
      assert decoded["Synopsis"] == "hello synopsis"
      assert decoded["Notes"] == "main notes here"
    end

    test "does nothing if notes.md does not exist" do
      File.rm_rf!(notes_md_path())
      File.rm_rf!(notes_json_path())
      assert :ok = Notes.upgrade_to_json()
      refute File.exists?(notes_md_path())
      refute File.exists?(notes_json_path())
    end
  end
end
