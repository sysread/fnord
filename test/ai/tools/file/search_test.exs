defmodule AI.Tools.File.SearchTest do
  use Fnord.TestCase, async: false
  @moduletag capture_log: true

  setup do
    # Establish a real project context so Store.get_project/0 returns a project
    {:ok, project: mock_project("search_test")}
  end

  setup do
    # Prepare fresh mocks for each test where needed
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
    assert AI.Tools.File.Search.async?() == true
  end

  test "is_available?/0 delegates to AI.Tools.has_indexed_project/0" do
    :meck.expect(AI.Tools, :has_indexed_project, fn -> false end)
    assert AI.Tools.File.Search.is_available?() == false

    :meck.expect(AI.Tools, :has_indexed_project, fn -> true end)
    assert AI.Tools.File.Search.is_available?() == true
  end

  test "read_args/1 extracts query" do
    assert AI.Tools.File.Search.read_args(%{"query" => "foo"}) == {:ok, %{"query" => "foo"}}
  end

  test "spec/0 returns the correct function schema" do
    spec = AI.Tools.File.Search.spec()
    assert spec.type == "function"

    f = spec.function
    assert f.name == "file_search_tool"
    assert f.strict == true

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

  test "call/1 returns formatted results when search and index_state succeed" do
    # Setup mocks for Search and Store modules
    for mod <- [Search.Files, Store.Project] do
      :meck.new(mod, [:passthrough])
    end

    :meck.expect(Search.Files, :get_results, fn _search ->
      {:ok,
       [
         {%{rel_path: "lib/foo.ex"}, 0.42, %{"summary" => "foo summary"}},
         {%{rel_path: "lib/bar.ex"}, 0.21, %{"summary" => "bar summary"}}
       ]}
    end)

    :meck.expect(Store.Project, :index_status, fn _proj ->
      %{new: [1], stale: [1, 2], deleted: []}
    end)

    {:ok, msg} = AI.Tools.File.Search.call(%{"query" => "anything"})

    assert msg =~ "[search_tool]"
    assert msg =~ "# `lib/foo.ex` (cosine similarity: 0.42)"
    assert msg =~ "foo summary"
    assert msg =~ "# `lib/bar.ex` (cosine similarity: 0.21)"
    assert msg =~ "bar summary"

    assert msg =~ "- New files (not yet indexed): 1"
    assert msg =~ "- Stale files (outdated index): 2"
    assert msg =~ "- Deleted files (indexed but deleted in project): 0"

    # Clean up mocks
    for mod <- [Search.Files, Store.Project] do
      :meck.unload(mod)
    end
  end

  test "call/1 propagates search errors" do
    :meck.new(Search.Files, [:passthrough])
    :meck.expect(Search.Files, :get_results, fn _ -> {:error, :boom} end)
    assert AI.Tools.File.Search.call(%{"query" => "q"}) == {:error, :boom}
    :meck.unload(Search.Files)
  end

  test "call/1 propagates index_state errors" do
    :meck.new(Search.Files, [:passthrough])
    :meck.expect(Search.Files, :get_results, fn _ -> {:ok, []} end)
    :meck.new(Store, [:passthrough])
    :meck.expect(Store, :get_project, fn -> {:error, :proj_missing} end)
    assert AI.Tools.File.Search.call(%{"query" => "q"}) == {:error, :proj_missing}
    :meck.unload(Search.Files)
    :meck.unload(Store)
  end
end
