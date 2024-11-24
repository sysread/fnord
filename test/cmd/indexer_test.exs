defmodule Cmd.IndexerTest do
  use ExUnit.Case

  setup do
    # Save the current log level
    current_level = Logger.level()

    # Disable logging
    Logger.configure(level: :none)

    # Return the current log level to restore later
    on_exit(fn ->
      Logger.configure(level: current_level)
    end)

    :ok
  end

  setup do
    # Create a temporary home directory for our app to store data
    {:ok, home_dir} = Briefly.create(directory: true)

    # Create a temporary project directory and initialize it as a git repo
    {:ok, project_dir} = Briefly.create(directory: true)

    System.cmd("git", ["init"],
      cd: project_dir,
      env: [
        {"GIT_TRACE", "0"},
        {"GIT_CURL_VERBOSE", "0"},
        {"GIT_DEBUG", "0"}
      ]
    )

    # Temporarily override the HOME environment variable
    original_home = System.get_env("HOME")
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    {:ok, home_dir: home_dir, store_dir: Path.join(home_dir, ".fnord"), project_dir: project_dir}
  end

  test "--directory", %{project_dir: project_dir} do
    # Ensure an error is raised an error if directory is not provided when the
    # project root is not in settings.
    raises_error =
      try do
        Cmd.Indexer.new(%{project: "test_project"}, MockIndexer)
        false
      rescue
        _ -> true
      end

    assert raises_error

    # This should create the settings entry
    Cmd.Indexer.new(
      %{
        project: "test_project",
        directory: project_dir
      },
      MockIndexer
    )

    # Now this should *not* raise an error
    raises_error =
      try do
        Cmd.Indexer.new(%{project: "test_project"}, MockIndexer)
        false
      rescue
        _ -> true
      end

    refute raises_error
  end

  test "run/4", %{store_dir: store_dir, project_dir: project_dir} do
    file_1 = Path.join(project_dir, "file1.txt")
    file_2 = Path.join(project_dir, "file2.txt")

    # Insert a couple of files into the project
    File.write!(file_1, "file1")
    File.write!(file_2, "file2")

    # Make file2 git-ignored
    File.write!(Path.join(project_dir, ".gitignore"), "file2.txt")

    # Create an indexer for the project
    idx =
      Cmd.Indexer.new(
        %{
          project: "test_project",
          directory: project_dir,
          quiet: true
        },
        MockIndexer
      )

    # Run the indexing process
    Cmd.Indexer.run(idx)

    # Check that the files were indexed
    assert File.dir?(Path.join(store_dir, "test_project"))
    assert Store.list_projects() == ["test_project"]
    assert Store.list_files(idx.store) == [file_1]
  end
end

defmodule MockIndexer do
  defstruct []

  @behaviour Indexer

  @impl Indexer
  def new() do
    %MockIndexer{}
  end

  @impl Indexer
  def get_embeddings(_idx, _text) do
    {:ok, ["embedding1", "embedding2"]}
  end

  @impl Indexer
  def get_summary(_idx, _project, _file, _text) do
    {:ok, "summary"}
  end

  @impl Indexer
  def get_outline(_idx, _project, _file, _text) do
    {:ok, "outline"}
  end
end
