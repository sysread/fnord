defmodule Cmd.SummaryTest do
  use Fnord.TestCase, async: false

  setup do: set_log_level(:none)
  setup do: {:ok, project: mock_project("summary_proj")}

  describe "run/3" do
    test "prints summary and outline for a stored file", %{project: project} do
      # Create a source file and index it
      File.mkdir_p!(Path.join(project.source_root, "lib"))
      file_path = mock_source_file(project, "lib/foo.ex", "defmodule Foo do end\n")

      idx = Cmd.Index.new(%{project: project.name, directory: project.source_root, quiet: true})
      Cmd.Index.perform_task(idx)

      {stdout, _stderr} = capture_all(fn -> Cmd.Summary.run(%{file: file_path}, [], []) end)

      assert stdout =~ "# File: `#{Path.absname(file_path)}`"
      assert stdout =~ "# Summary"
      assert stdout =~ "summary"
      assert stdout =~ "# Outline"
      assert stdout =~ "```"
      assert stdout =~ "outline"
    end

    test "returns error tuple when file is not in store (entry_not_found)", %{project: project} do
      # Create a file but do NOT index; should not exist in store
      file_path = Path.join(project.source_root, "lib/missing.ex")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "defmodule Missing do end\n")

      result = Cmd.Summary.run(%{file: file_path}, [], [])
      assert result == {:error, :entry_not_found}
    end

    test "returns error when project not set" do
      Services.Globals.put_env(:fnord, :project, nil)

      result = Cmd.Summary.run(%{file: "/tmp/some_file.ex"}, [], [])
      assert result == {:error, :project_not_set}
    end
  end
end
