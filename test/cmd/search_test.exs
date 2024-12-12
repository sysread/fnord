defmodule Cmd.SearchTest do
  use ExUnit.Case
  use TestUtil

  setup do: set_config(concurrency: 1, quiet: true)
  setup do: set_log_level(:none)

  setup do
    project = mock_project("test_project")
    {:ok, project: project}
  end

  test "search returns files ranked by similarity to query", %{project: project} do
    # Create sample files with known content
    file1 = mock_source_file(project, "file1.txt", "file1")
    file2 = mock_source_file(project, "file2.txt", "file2")
    file3 = mock_source_file(project, "file3.txt", "other content")

    # Index the files using the Indexer with MockIndexerForSearch
    idx =
      Cmd.Indexer.new(
        %{
          project: project.name,
          directory: project.source_root,
          quiet: true
        },
        MockIndexerForSearch
      )

    Cmd.Indexer.run(idx)

    # Define search options
    search_opts = %{
      project: "test_project",
      query: "file1",
      limit: 1,
      detail: false
    }

    # Capture the output of the Search.run/2 function
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Cmd.Search.run(search_opts, MockIndexerForSearch)
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

defmodule MockIndexerForSearch do
  defstruct []

  @behaviour Indexer

  @impl Indexer
  def new() do
    %MockIndexerForSearch{}
  end

  @impl Indexer
  def get_embeddings(_idx, text) do
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

  @impl Indexer
  def get_summary(_idx, _file, _text) do
    {:ok, "summary"}
  end

  @impl Indexer
  def get_outline(_idx, _file, _text) do
    {:ok, "outline"}
  end
end
