defmodule Cmd.IndexerTest do
  use ExUnit.Case
  use TestUtil

  setup_args(concurrency: 1, quiet: true)

  describe "run" do
    setup do
      project = mock_git_project("test_project")
      {:ok, project: project}
    end

    test "positive path", %{project: project} do
      file = mock_source_file(project, "file1.txt", "file1")
      mock_source_file(project, "file2.txt", "file2")

      # Make file2 git-ignored
      git_ignore(project, ["file2.txt"])

      # Create an indexer for the project
      idx = Cmd.Indexer.new(%{project: project.name, quiet: true}, MockIndexer)

      # Run the indexing process
      Cmd.Indexer.run(idx)

      # Check that the files were indexed
      Store.list_projects()
      |> Enum.map(& &1.name)
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
          Cmd.Indexer.new(%{project: "test_project"}, MockIndexer)
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
          Cmd.Indexer.new(%{project: "test_project", directory: tmp_dir}, MockIndexer)
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
          Cmd.Indexer.new(%{project: project.name}, MockIndexer)
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

defmodule MockIndexer do
  defstruct []

  @behaviour Indexer

  @impl Indexer
  def new(), do: %MockIndexer{}

  @impl Indexer
  def get_embeddings(_idx, _text), do: {:ok, [[1, 2, 3], [4, 5, 6]]}

  @impl Indexer
  def get_summary(_idx, _file, _text), do: {:ok, "summary"}

  @impl Indexer
  def get_outline(_idx, _file, _text), do: {:ok, "outline"}
end
