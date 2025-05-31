defmodule Cmd.IndexTest do
  use Fnord.TestCase

  setup do: set_config(workers: 1, quiet: true)

  describe "run" do
    setup do: {:ok, project: mock_git_project("test_project")}

    test "positive path", %{project: project} do
      file = mock_source_file(project, "file1.txt", "file1")
      mock_source_file(project, "file2.txt", "file2")

      # Make file2 git-ignored
      git_ignore(project, ["file2.txt"])

      # Create an indexer for the project
      idx = Cmd.Index.new(%{project: project.name, quiet: true})

      # Run the indexing process
      Cmd.Index.perform_task(idx)

      # Check that the files were indexed
      Settings.new()
      |> Settings.list_projects()
      |> then(&assert(&1 == ["test_project"]))

      Store.get_project("test_project")
      |> Store.Project.stored_files()
      |> Enum.map(& &1.file)
      |> then(&assert(&1 == [file]))
    end
  end

  describe "new" do
    test "raises an exception when source :directory is not passed or present in settings" do
      raises_error =
        try do
          Cmd.Index.new(%{project: "test_project"})
          false
        rescue
          _ -> true
        end

      assert raises_error
    end

    test "succeeds when source :directory is passed" do
      # Create a temp dir to be our source :directory
      {:ok, tmp_dir} = tmpdir()

      raises_error =
        try do
          Cmd.Index.new(%{project: "test_project", directory: tmp_dir})
          false
        rescue
          e ->
            IO.inspect(e, label: "An unexpected error was raised")
            true
        end

      refute raises_error
    end

    test "succeeds when source :directory is in settings" do
      # Create a new project in a temp dir with saved settings
      project = mock_project("test_project")

      raises_error =
        try do
          Cmd.Index.new(%{project: project.name})
          false
        rescue
          e ->
            IO.inspect(e, label: "An unexpected error was raised")
            true
        end

      refute raises_error
    end
  end
end
