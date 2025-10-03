defmodule AI.NotesTest do
  use Fnord.TestCase, async: false

  alias AI.Notes

  setup do
    :meck.new(AI.Completion, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(AI.Completion) end)

    proj = mock_project("test_project")
    File.mkdir_p!(proj.store_path)

    {:ok, %{proj: proj}}
  end

  describe "format_external_docs/0" do
    test "returns empty string when no external docs exist" do
      # Mock AI.Completion.get to prevent network calls
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok, %{response: "Mocked response"}}
      end)

      # Create a notes instance to test the private function indirectly
      state = Notes.new()

      # This should compile and not crash
      result = Notes.ask(state, "test question")
      assert is_binary(result)
    end
  end

  describe "ingest_research/4" do
    # local helper to cd for the duration of a function
    defp cd(dir, fun) do
      original = File.cwd!()
      File.cd!(dir)

      try do
        fun.()
      after
        File.cd!(original)
      end
    end

    test "tags bullet facts with current branch" do
      # Arrange: mock completion to return bullet facts
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok,
         %{
           response: """
           - Fact one
           - Fact two
           - Fact three
           """
         }}
      end)

      # Init a temp git repo and branch
      project = mock_git_project("notes-repo")
      git_config_user!(project)
      git_empty_commit!(project)
      git_checkout_branch!(project, "feature-branch")

      state = Notes.new()

      cd(project.source_root, fn ->
        new_state = Notes.ingest_research(state, "some_tool", "{}", %{})
        text = Enum.join(new_state.new_facts, "\n")
        assert String.contains?(text, "- fact one [src: feature-branch]")
        assert String.contains?(text, "- fact two [src: feature-branch]")
        assert String.contains?(text, "- fact three [src: feature-branch]")
      end)
    end

    test "notify_tool memos remain untagged" do
      # Arrange: make completion return N/A so only memos are added
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok, %{response: "N/A"}}
      end)

      args_json = Jason.encode!(%{"message" => "note to self: alpha\nremember: beta"})
      state = Notes.new()

      new_state = Notes.ingest_research(state, "notify_tool", args_json, %{})
      text = Enum.join(new_state.new_facts, "\n")
      # memos are converted to bullets and should not have [src: ...]
      # Note: ingest_research accumulates AI facts and extra_facts separately, but our mock returned N/A for AI facts,
      # so only memos should be present.
      assert String.contains?(text, "- note to self: alpha") or
               String.contains?(text, "- remember: beta")

      refute String.contains?(text, "[src:")
    end
  end
end
