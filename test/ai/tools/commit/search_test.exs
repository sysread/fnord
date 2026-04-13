defmodule AI.Tools.Commit.SearchTest do
  use Fnord.TestCase, async: false
  @moduletag capture_log: true

  setup do
    {:ok, project: mock_project("commit_search_test")}
  end

  setup do
    :meck.new(AI.Tools, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(AI.Tools)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "async?/0 returns true" do
    assert AI.Tools.Commit.Search.async?() == true
  end

  test "is_available?/0 delegates to AI.Tools.has_indexed_project/0" do
    :meck.expect(AI.Tools, :has_indexed_project, fn -> false end)
    assert AI.Tools.Commit.Search.is_available?() == false

    :meck.expect(AI.Tools, :has_indexed_project, fn -> true end)
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

    f = spec.function
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

  test "call/1 returns formatted results when search and index_state succeed" do
    for mod <- [Search.Commits, Store.Project, Store, Store.Project.CommitIndex] do
      safe_meck_new(mod, [:passthrough])
    end

    on_exit(fn ->
      for mod <- [Search.Commits, Store.Project, Store, Store.Project.CommitIndex] do
        safe_meck_unload(mod)
      end
    end)

    :meck.expect(Search.Commits, :get_results, fn _search ->
      {:ok,
       [
         {"abc123", 0.42, %{"subject" => "first", "author" => "A", "committed_at" => "t1"}},
         {"def456", 0.21, %{"subject" => "second", "author" => "B", "committed_at" => "t2"}}
       ]}
    end)

    :meck.expect(Store, :get_project, fn -> {:ok, mock_project("commit_search_test")} end)

    :meck.expect(Store.Project.CommitIndex, :index_status, fn _proj ->
      %{new: [1], stale: [1, 2], deleted: []}
    end)

    {:ok, msg} = AI.Tools.Commit.Search.call(%{"query" => "anything"})

    assert msg =~ "[commit_search_tool]"
    assert msg =~ "# abc123 (cosine similarity: 0.42)"
    assert msg =~ "- subject: first"
    assert msg =~ "- author: A"
    assert msg =~ "- committed_at: t1"

    assert msg =~ "# def456 (cosine similarity: 0.21)"
    assert msg =~ "- subject: second"
    assert msg =~ "- author: B"
    assert msg =~ "- committed_at: t2"

    assert msg =~ "- New commits (not yet embedded): 1"
    assert msg =~ "- Stale commits (outdated index): 2"
    assert msg =~ "- Deleted commits (indexed but missing from repo): 0"
  end

  test "call/1 propagates search errors" do
    safe_meck_new(Search.Commits, [:passthrough])
    on_exit(fn -> safe_meck_unload(Search.Commits) end)

    :meck.expect(Search.Commits, :get_results, fn _ -> {:error, :boom} end)
    assert AI.Tools.Commit.Search.call(%{"query" => "q"}) == {:error, :boom}
  end

  test "call/1 propagates index_state errors" do
    safe_meck_new(Search.Commits, [:passthrough])
    safe_meck_new(Store, [:passthrough])

    on_exit(fn ->
      safe_meck_unload(Search.Commits)
      safe_meck_unload(Store)
    end)

    :meck.expect(Search.Commits, :get_results, fn _ -> {:ok, []} end)
    :meck.expect(Store, :get_project, fn -> {:error, :proj_missing} end)
    assert AI.Tools.Commit.Search.call(%{"query" => "q"}) == {:error, :proj_missing}
  end
end
