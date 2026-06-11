defmodule AI.Tools.File.SearchTest do
  use Fnord.TestCase, async: true
  @moduletag capture_log: true

  # ---------------------------------------------------------------------------
  # These tests run the real search pipeline end to end: files are written to
  # the project source, indexed for real through Cmd.Index (embeddings and
  # summaries canned via MockIndexer), and scored by the real Search.Files
  # cosine ranking. Only the AI boundary (MockIndexer) is canned.
  # ---------------------------------------------------------------------------

  setup do
    {:ok, project: mock_project("search_test")}
  end

  test "async?/0 returns true" do
    assert AI.Tools.File.Search.async?() == true
  end

  test "is_available?/0 reflects whether the project has a file index", %{project: project} do
    refute AI.Tools.File.Search.is_available?()

    entry_dir = Path.join(Store.Project.files_root(project), "stub_entry")
    File.mkdir_p!(entry_dir)
    File.write!(Path.join(entry_dir, "embeddings.json"), "[]")

    assert AI.Tools.File.Search.is_available?() == true
  end

  test "read_args/1 extracts query" do
    assert AI.Tools.File.Search.read_args(%{"query" => "foo"}) == {:ok, %{"query" => "foo"}}
  end

  test "spec/0 returns the correct function schema" do
    spec = AI.Tools.File.Search.spec()
    assert spec.type == "function"

    f = spec
    assert f.name == "file_search_tool"

    params = f.parameters
    assert params.additionalProperties == false
    assert params.required == ["query"]
    assert params.properties.query.type == "string"
  end

  test "ui_note_on_request/1 and ui_note_on_result/2" do
    assert AI.Tools.File.Search.ui_note_on_request(%{"query" => "bar"}) ==
             {"Semantic search", "bar"}

    assert {"Semantic search", "bar -> 2 file matches in 123 ms"} =
             AI.Tools.File.Search.ui_note_on_result(%{"query" => "bar"}, """
             Semantic search found 2 matching files in 123 ms:
             """)
  end

  test "call/1 returns formatted results ranked by similarity", %{project: project} do
    # One-hot embeddings keyed off content: the query and file1 share a
    # dimension (cosine 1.0); file2 is orthogonal (cosine 0.0).
    Mox.stub(MockIndexer, :get_embeddings, fn text ->
      base = List.duplicate(0.0, 384)

      cond do
        String.contains?(text, "file1") -> {:ok, List.replace_at(base, 0, 1.0)}
        String.contains?(text, "file2") -> {:ok, List.replace_at(base, 1, 1.0)}
        true -> {:ok, base}
      end
    end)

    Mox.stub(MockIndexer, :get_summary, fn _file, content ->
      {:ok, "summary of #{content}"}
    end)

    mock_source_file(project, "file1.txt", "file1")
    mock_source_file(project, "file2.txt", "file2")

    idx =
      Cmd.Index.new(%{
        project: project.name,
        directory: project.source_root,
        quiet: true
      })

    Cmd.Index.perform_task(idx)

    # Added after indexing: shows up in the index-state footer as new.
    mock_source_file(project, "file3.txt", "unindexed")

    {:ok, msg} = AI.Tools.File.Search.call(%{"query" => "file1"})

    assert msg =~ "[search_tool]"
    assert msg =~ "# `file1.txt` (cosine similarity: 1.0)"
    assert msg =~ "summary of file1"
    assert msg =~ "# `file2.txt` (cosine similarity: 0.0)"
    assert msg =~ "summary of file2"

    # Higher similarity sorts first.
    {file1_idx, _} = :binary.match(msg, "# `file1.txt`")
    {file2_idx, _} = :binary.match(msg, "# `file2.txt`")
    assert file1_idx < file2_idx

    assert msg =~ "- New files (not yet indexed): 1"
    assert msg =~ "- Stale files (outdated index): 0"
    assert msg =~ "- Deleted files (indexed but deleted in project): 0"
  end

  test "call/1 propagates search errors" do
    Mox.stub(MockIndexer, :get_embeddings, fn _ -> {:error, :boom} end)
    assert AI.Tools.File.Search.call(%{"query" => "q"}) == {:error, :boom}
  end

  test "call/1 propagates store errors when no project is selected" do
    set_config(:project, nil)
    assert AI.Tools.File.Search.call(%{"query" => "q"}) == {:error, :project_not_set}
  end
end
