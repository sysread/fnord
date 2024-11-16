defmodule Cmd.SearchTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  setup do
    # Create temporary directories for the home and project
    {:ok, home_dir} = Briefly.create(directory: true)
    {:ok, project_dir} = Briefly.create(directory: true)

    # Initialize the project directory as a git repository
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

    {:ok, home_dir: home_dir, project_dir: project_dir}
  end

  test "search returns files ranked by similarity to query", %{
    project_dir: project_dir
  } do
    # Create sample files with known content
    file1 = Path.join(project_dir, "file1.txt")
    File.write!(file1, "file1")

    file2 = Path.join(project_dir, "file2.txt")
    File.write!(file2, "file2")

    file3 = Path.join(project_dir, "file3.txt")
    File.write!(file3, "other content")

    # Index the files using the Indexer with MockAIForSearch
    idx =
      Cmd.Indexer.new(
        %{
          project: "test_project",
          directory: project_dir,
          quiet: true
        },
        MockAIForSearch
      )

    Cmd.Indexer.run(idx)

    # Define search options
    search_opts = %{
      project: "test_project",
      query: "file1",
      limit: 1,
      detail: false,
      concurrency: 1
    }

    # Capture the output of the Search.run/2 function
    output =
      capture_io(fn ->
        Cmd.Search.run(search_opts, MockAIForSearch)
      end)

    # Split the output into lines
    results = output |> String.split("\n", trim: true)

    # Assert that file1.txt is the first result
    assert List.first(results) == file1

    # Assert that file2.txt and file3.txt are not in the results (since they have lower similarity)
    refute Enum.member?(results, file2)
    refute Enum.member?(results, file3)
  end
end

defmodule MockAIForSearch do
  defstruct []

  @behaviour AI

  @impl AI
  def new() do
    %MockAIForSearch{}
  end

  @impl AI
  def get_embeddings(_ai, text) do
    embedding =
      cond do
        String.contains?(text, "file1") ->
          Enum.concat([1.0], List.duplicate(0.0, 3071))

        String.contains?(text, "file2") ->
          Enum.concat([0.0, 1.0], List.duplicate(0.0, 3071))

        String.contains?(text, "other content") ->
          Enum.concat([0.0, 0.0, 1.0], List.duplicate(0.0, 3070))

        true ->
          List.duplicate(0.0, 3072)
      end

    {:ok, [embedding]}
  end

  @impl AI
  def get_summary(_ai, _file, _text) do
    {:ok, "summary"}
  end
end
