defmodule AI.Tools.Commit.SearchTest do
  use Fnord.TestCase, async: true
  @moduletag capture_log: true

  # ---------------------------------------------------------------------------
  # These tests run the real search pipeline over a real tmpdir store: commit
  # entries are written with CommitIndex.write_embeddings and scored against
  # a query vector canned through MockIndexer. The mock project dir is not a
  # git repo, so index_status sees no source commits - indexed entries
  # therefore classify as deleted, which the footer assertions reflect.
  # ---------------------------------------------------------------------------

  alias Store.Project.CommitIndex

  setup do
    {:ok, project: mock_project("commit_search_test")}
  end

  test "async?/0 returns true" do
    assert AI.Tools.Commit.Search.async?() == true
  end

  test "is_available?/0 reflects whether the project has a file index", %{project: project} do
    # Fresh project: no embeddings on disk anywhere.
    refute AI.Tools.Commit.Search.is_available?()

    # Fabricate a minimal file index entry; availability flips on.
    entry_dir = Path.join(Store.Project.files_root(project), "stub_entry")
    File.mkdir_p!(entry_dir)
    File.write!(Path.join(entry_dir, "embeddings.json"), "[]")

    assert AI.Tools.Commit.Search.is_available?() == true
  end

  test "read_args/1 extracts and normalizes args" do
    assert {:ok, %{"query" => "foo", "limit" => 25}} =
             AI.Tools.Commit.Search.read_args(%{"query" => "foo"})

    assert {:ok, %{"query" => "bar", "limit" => 10}} =
             AI.Tools.Commit.Search.read_args(%{"query" => "bar", "limit" => 10})
  end

  test "spec/0 returns the correct function schema" do
    spec = AI.Tools.Commit.Search.spec()
    assert spec.type == "function"

    f = spec
    assert f.name == "commit_search_tool"

    params = f.parameters
    assert params.additionalProperties == false
    assert params.required == ["query"]
    assert params.properties.query.type == "string"
    assert params.properties.limit.type == "integer"
  end

  test "ui_note_on_request/1 and ui_note_on_result/2" do
    assert AI.Tools.Commit.Search.ui_note_on_request(%{"query" => "bar"}) ==
             {"Commit search", "bar"}

    assert {"Commit search", "bar -> 2 commit matches in 123 ms"} =
             AI.Tools.Commit.Search.ui_note_on_result(%{"query" => "bar"}, """
             Commit search found 2 matching commits in 123 ms:
             """)
  end

  test "call/1 returns formatted results ranked by similarity", %{project: project} do
    # The query embeds to [1.0, 0.0]; abc123's stored vector is identical
    # (cosine 1.0) and def456's is orthogonal (cosine 0.0), pinning the
    # ranking without depending on float formatting beyond the exact cases.
    Mox.stub(MockIndexer, :get_embeddings, fn "anything" -> {:ok, [1.0, 0.0]} end)

    :ok =
      CommitIndex.write_embeddings(project, "abc123", [1.0, 0.0], %{
        "subject" => "first",
        "author" => "A",
        "committed_at" => "t1"
      })

    :ok =
      CommitIndex.write_embeddings(project, "def456", [0.0, 1.0], %{
        "subject" => "second",
        "author" => "B",
        "committed_at" => "t2"
      })

    {:ok, msg} = AI.Tools.Commit.Search.call(%{"query" => "anything", "limit" => 25})

    assert msg =~ "[commit_search_tool]"
    assert msg =~ "# abc123 (cosine similarity: 1.0)"
    assert msg =~ "- subject: first"
    assert msg =~ "- author: A"
    assert msg =~ "- committed_at: t1"

    assert msg =~ "# def456 (cosine similarity: 0.0)"
    assert msg =~ "- subject: second"
    assert msg =~ "- author: B"
    assert msg =~ "- committed_at: t2"

    # Higher similarity sorts first.
    {abc_idx, _} = :binary.match(msg, "# abc123")
    {def_idx, _} = :binary.match(msg, "# def456")
    assert abc_idx < def_idx

    # No source repo: both indexed commits classify as deleted.
    assert msg =~ "- New commits (not yet embedded): 0"
    assert msg =~ "- Stale commits (outdated index): 0"
    assert msg =~ "- Deleted commits (indexed but missing from repo): 2"
  end

  test "call/1 propagates search errors" do
    Mox.stub(MockIndexer, :get_embeddings, fn _ -> {:error, :boom} end)
    assert AI.Tools.Commit.Search.call(%{"query" => "q", "limit" => 25}) == {:error, :boom}
  end

  test "call/1 propagates store errors when no project is selected" do
    set_config(:project, nil)

    assert AI.Tools.Commit.Search.call(%{"query" => "q", "limit" => 25}) ==
             {:error, :project_not_set}
  end
end
