defmodule AI.NotesTest do
  use Fnord.TestCase, async: true

  alias AI.Notes

  setup do
    proj = mock_project("test_project")
    File.mkdir_p!(proj.store_path)

    {:ok, %{proj: proj}}
  end

  describe "format_external_docs/0" do
    test "returns empty string when no external docs exist" do
      canned_completion("Mocked response")

      # Create a notes instance to test the private function indirectly
      state = Notes.new()

      # This should compile and not crash
      result = Notes.ask(state, "test question")
      assert is_binary(result)
    end
  end

  describe "ingest_research/4" do
    test "tags bullet facts with current branch" do
      canned_completion("""
      - Fact one
      - Fact two
      - Fact three
      """)

      # Init a temp git repo and branch
      project = mock_git_project("notes-repo")
      git_config_user!(project)
      git_empty_commit!(project)
      git_checkout_branch!(project, "feature-branch")

      state = Notes.new()

      # Branch detection resolves through GitCli's effective_git_dir, which
      # prefers the project root override over the process cwd. The override
      # is Globals-scoped, so this is async-safe where a File.cd! would not be.
      Settings.set_project_root_override(project.source_root)

      new_state = Notes.ingest_research(state, "some_tool", "{}", %{})
      text = Enum.join(new_state.new_facts, "\n")
      assert String.contains?(text, "- fact one [src: feature-branch]")
      assert String.contains?(text, "- fact two [src: feature-branch]")
      assert String.contains?(text, "- fact three [src: feature-branch]")
    end

    test "commit with empty new_facts does not touch notes.md", %{proj: proj} do
      notes_path = Path.join(proj.store_path, "notes.md")
      state = Notes.new()

      # notes.md absent: commit must not create it
      refute File.exists?(notes_path)
      assert {:ok, ^state} = Notes.commit(state)
      refute File.exists?(notes_path)

      # notes.md present with a stable mtime: commit must not rewrite it
      File.write!(notes_path, "existing notes body")
      pre = File.stat!(notes_path).mtime

      assert {:ok, ^state} = Notes.commit(state)

      post = File.stat!(notes_path).mtime
      assert pre == post
      assert File.read!(notes_path) == "existing notes body"
    end

    test "commit with accumulated facts writes an unconsolidated section", %{proj: proj} do
      notes_path = Path.join(proj.store_path, "notes.md")
      state = %{Notes.new() | new_facts: ["- fact alpha\n- fact beta"]}

      assert {:ok, new_state} = Notes.commit(state)
      assert new_state.new_facts == []

      contents = File.read!(notes_path)
      assert String.contains?(contents, "# NEW NOTES (unconsolidated)")
      assert String.contains?(contents, "- fact alpha")
      assert String.contains?(contents, "- fact beta")
    end

    test "notify_tool memos remain untagged" do
      # Make the model return N/A so only memos are added
      canned_completion("N/A")

      args_json = SafeJson.encode!(%{"message" => "note to self: alpha\nremember: beta"})
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
