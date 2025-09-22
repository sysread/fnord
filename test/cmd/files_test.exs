defmodule Cmd.FilesTest do
  use Fnord.TestCase, async: false

  setup do: set_log_level(:none)

  describe "run/3" do
    test "lists all indexed files sorted by rel_path" do
      # Create a mock project and some files
      project = mock_project("files_project")

      # Create files (unordered)
      mock_source_file(project, "z.txt", "z")
      # Ensure the parent directory exists before creating a/b.txt
      File.mkdir_p!(Path.join(project.source_root, "a"))
      mock_source_file(project, "a/b.txt", "ab")
      mock_source_file(project, "m.ex", "m")

      # Index the files so they appear in the store
      idx = Cmd.Index.new(%{project: project.name, directory: project.source_root, quiet: true})
      Cmd.Index.perform_task(idx)

      {stdout, _stderr} = capture_all(fn -> Cmd.Files.run(%{}, [], []) end)

      lines =
        stdout
        |> String.split("\n", trim: true)

      assert lines == ["a/b.txt", "m.ex", "z.txt"]
    end

    test "returns error and prints nothing when no project is selected" do
      # Ensure no default project is set
      Services.Globals.put_env(:fnord, :project, nil)

      {stdout, _stderr} = capture_all(fn -> Cmd.Files.run(%{}, [], []) end)
      # Cmd.Files.run/3 will propagate the error from Store.get_project/0
      result = Cmd.Files.run(%{}, [], [])

      assert stdout == ""
      assert result == {:error, :project_not_set}
    end
  end
end
