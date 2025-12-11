defmodule Cmd.SearchTest do
  use Fnord.TestCase, async: false

  import LayoutMigrationHelpers

  setup do: set_log_level(:none)
  setup do: {:ok, project: mock_project("test_project")}

  test "search returns files ranked by similarity to query", %{project: project} do
    MockIndexer
    |> Mox.stub(:get_embeddings, fn text ->
      base = List.duplicate(0.0, 3072)

      embedding =
        cond do
          String.contains?(text, "file1") ->
            base |> List.replace_at(0, 1.0)

          String.contains?(text, "file2") ->
            base |> List.replace_at(1, 1.0)

          String.contains?(text, "other content") ->
            base |> List.replace_at(2, 1.0)

          true ->
            List.duplicate(0.0, 3072)
        end

      {:ok, embedding}
    end)

    # Create sample files with known content
    file1 = mock_source_file(project, "file1.txt", "file1")
    file2 = mock_source_file(project, "file2.txt", "file2")
    file3 = mock_source_file(project, "file3.txt", "other content")

    # Index the files
    idx =
      Cmd.Index.new(%{
        project: project.name,
        directory: project.source_root,
        quiet: true
      })

    Cmd.Index.perform_task(idx)

    # Define search options
    search_opts = %{
      project: "test_project",
      query: "file1",
      limit: 1,
      detail: false
    }

    # Capture the output of the Search.run/2 function
    {output, _stderr} =
      capture_all(fn ->
        Cmd.Search.run(search_opts, [], [])
      end)

    # Split the output into lines
    results =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> String.split(line, "\t") end)
      |> Enum.map(fn [_similarity, file] -> file end)

    # Assert that file1.txt is the first result
    assert List.first(results) == file1

    # Assert that file2.txt and file3.txt are not in the results (since they have lower similarity)
    refute Enum.member?(results, file2)
    refute Enum.member?(results, file3)
  end

  describe "migration of legacy root-level entries" do
    test "migrates legacy entries and is idempotent", %{project: project} do
      # Create a legacy entry at project root
      {basename, rel_file} = create_legacy_entry(project)
      legacy_dir = Path.join(project.store_path, basename)
      # Provide minimal embeddings.json for search
      File.write!(Path.join(legacy_dir, "embeddings.json"), Jason.encode!(%{"embeddings" => []}))
      # Stub indexer to return zero-vector embeddings
      MockIndexer |> Mox.stub(:get_embeddings, fn _text -> {:ok, List.duplicate(0.0, 3072)} end)
      # Define search options
      search_opts = %{
        project: project.name,
        query: rel_file,
        limit: 10,
        detail: false
      }

      # First run: should migrate and find the file
      {out1, _} = capture_all(fn -> Cmd.Search.run(search_opts, [], []) end)
      assert_migrated(project, basename, rel_file)
      # Second run: idempotent, same output
      {out2, _} = capture_all(fn -> Cmd.Search.run(search_opts, [], []) end)
      assert out2 == out1
    end
  end
end
