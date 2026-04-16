defmodule Cmd.IndexTest do
  use Fnord.TestCase, async: false

  setup do
    set_config(workers: 1)

    # Stub the conversation summarizer so it doesn't hit the real LLM
    :meck.new(AI.Agent.ConversationSummary, [:no_link, :passthrough])
    :meck.expect(AI.Agent.ConversationSummary, :get_response, fn _opts -> {:ok, "test summary"} end)
    on_exit(fn -> :meck.unload(AI.Agent.ConversationSummary) end)
  end

  describe "run" do
    setup do
      {:ok, project: mock_git_project("test_project")}
    end

    test "positive path", %{project: project} do
      file = mock_source_file(project, "file1.txt", "file1")
      mock_source_file(project, "file2.txt", "file2")

      # Make file2 git-ignored
      git_ignore(project, ["file2.txt"])

      # Create an indexer for the project
      assert {:ok, idx} = Cmd.Index.new(%{project: project.name, quiet: true, yes: true})

      # Run the indexing process
      Cmd.Index.perform_task({:ok, idx})

      # Check that the files were indexed
      Settings.new()
      |> Settings.list_projects()
      |> then(&assert(&1 == ["test_project"]))

      {:ok, project} = Store.get_project("test_project")

      project
      |> Store.Project.stored_files()
      |> Enum.map(& &1.file)
      |> then(&assert(&1 == [file]))
    end

    test "project-level approvals are preserved when indexing persists settings", %{
      project: project
    } do
      # Approve a shell command at project level
      Settings.new()
      |> Settings.Approvals.approve(:project, "shell", "git status")

      # Run indexing with explicit directory to persist settings
      capture_all(fn ->
        Cmd.Index.run(
          %{project: project.name, directory: project.source_root, yes: true, quiet: true},
          [],
          []
        )
      end)

      # Assert the approval still exists
      approvals =
        Settings.new()
        |> Settings.Approvals.get_approvals(:project, "shell")

      assert "git status" in approvals
    end

    test "indexes conversations as part of run/3", %{project: project} do
      conversation = Store.Project.Conversation.new("conv1", project)
      messages = [AI.Util.system_msg("Hello")]

      {:ok, _} =
        Store.Project.Conversation.write(conversation, %{
          messages: messages,
          metadata: %{},
          memories: []
        })

      # Conversation indexing runs regardless of git status; only commit work is gated.
      Services.Globals.put_env(:fnord, :indexer, StubIndexer)

      Cmd.Index.run(%{project: project.name, yes: true, quiet: true}, [], [])

      {:ok, project} = Store.get_project(project.name)

      status = Store.Project.ConversationIndex.index_status(project)
      assert status.new == []
      assert status.stale == []

      embeddings_list =
        Store.Project.ConversationIndex.all_embeddings(project)
        |> Enum.into([])

      assert Enum.any?(embeddings_list, fn {id, _emb, _meta} -> id == conversation.id end)
    end

    test "invokes commit indexing only in git projects", %{project: project} do
      file = mock_source_file(project, "file1.txt", "file1")
      {:ok, idx} = Cmd.Index.new(%{project: project.name, yes: true, quiet: true})

      :meck.new(Cmd.Index, [:non_strict, :passthrough])
      :meck.expect(GitCli, :ignored_files, fn _ -> %{} end)
      :meck.expect(GitCli, :is_git_repo_at?, fn _ -> true end)

      on_exit(fn ->
        :meck.unload(GitCli)
      end)

      assert :ok = Cmd.Index.perform_task({:ok, idx})
      {:ok, project} = Store.get_project(project.name)
      entries = Store.Project.index_status(project)
      assert [] = entries.new
      assert [] = entries.stale
      entry = Store.Project.Entry.new_from_file_path(project, file)
      assert Store.Project.Entry.exists_in_store?(entry)
      assert :meck.called(GitCli, :is_git_repo_at?, :_)
    end

    test "skips commit indexing in non-git projects" do
      project = mock_project("non_git_commit_index")
      file = mock_source_file(project, "file1.txt", "file1")
      {:ok, idx} = Cmd.Index.new(%{project: project.name, yes: true, quiet: true})

      :meck.new(Cmd.Index, [:non_strict, :passthrough])
      :meck.expect(GitCli, :ignored_files, fn _ -> %{} end)
      :meck.expect(GitCli, :is_git_repo_at?, fn _ -> false end)

      on_exit(fn ->
        :meck.unload(GitCli)
      end)

      assert :ok = Cmd.Index.perform_task({:ok, idx})
      {:ok, project} = Store.get_project(project.name)
      entries = Store.Project.index_status(project)
      assert [] = entries.new
      assert [] = entries.stale
      entry = Store.Project.Entry.new_from_file_path(project, file)
      assert Store.Project.Entry.exists_in_store?(entry)
      assert :meck.called(GitCli, :is_git_repo_at?, :_)
    end

    test "indexes commits as part of the foreground run path", %{project: project} do
      git_config_user!(project)
      File.write!(Path.join(project.source_root, "tracked.txt"), "one")
      System.cmd("git", ["add", "."], cd: project.source_root)
      System.cmd("git", ["commit", "-m", "first", "--quiet"], cd: project.source_root)

      Services.Globals.put_env(:fnord, :indexer, StubIndexer)

      assert {:ok, idx} = Cmd.Index.new(%{project: project.name, yes: true, quiet: true})
      assert :ok = Cmd.Index.perform_task({:ok, idx})

      {:ok, project} = Store.get_project(project.name)

      head_sha =
        System.cmd("git", ["rev-parse", "HEAD"], cd: project.source_root)
        |> elem(0)
        |> String.trim()

      embeddings_list =
        Store.Project.CommitIndex.all_embeddings(project)
        |> Enum.into([])

      assert embeddings_list != []

      assert Enum.any?(embeddings_list, fn {id, emb, meta} ->
               id == head_sha and is_list(emb) and emb != [] and Enum.any?(emb, &(&1 != 0.0)) and
                 meta["sha"] == head_sha and Map.has_key?(meta, "doc_hash") and
                 Map.has_key?(meta, "index_format_version")
             end)

      status = Store.Project.CommitIndex.index_status(project)
      assert status.new == []
    end
  end

  describe "cooperative indexing" do
    setup do
      Services.Globals.put_env(:fnord, :indexer, StubIndexer)
      :ok
    end

    test "second run classifies all entries as fresh (no new/stale)" do
      project = mock_project("coop_fresh")
      mock_source_file(project, "a.txt", "hello")
      mock_source_file(project, "b.txt", "world")

      {:ok, idx} = Cmd.Index.new(%{project: project.name, yes: true, quiet: true})
      assert :ok = Cmd.Index.perform_task({:ok, idx})

      # Scan the project again: hash_is_current? should be true for every
      # entry, so nothing shows up in the stale or new buckets. This is
      # the observable proxy for "the worker didn't need to re-run the
      # indexer on the second pass" - index_status short-circuits before
      # any per-item work.
      {:ok, project} = Store.get_project("coop_fresh")
      status = Store.Project.index_status(project)

      assert status.stale == []
      assert status.new == []
    end

    test "binary files don't crash and aren't persisted as entries" do
      project = mock_project("coop_binary")
      binary_path = Path.join(project.source_root, "blob.bin")

      # A deliberately non-UTF-8 byte sequence. Passing this through
      # AI.Splitter / String.split_at would crash the grapheme walker
      # before the branch's guard_text was added.
      File.write!(binary_path, <<0xFF, 0xFE, 0xFD, 0x00, 0xA0>>)
      mock_source_file(project, "text.txt", "normal file")

      {:ok, idx} = Cmd.Index.new(%{project: project.name, yes: true, quiet: true})
      assert :ok = Cmd.Index.perform_task({:ok, idx})

      # The text file got an entry; the binary file did not.
      {:ok, project} = Store.get_project("coop_binary")
      files =
        project
        |> Store.Project.stored_files()
        |> Enum.map(& &1.rel_path)
        |> Enum.sort()

      assert "text.txt" in files
      refute "blob.bin" in files
    end
  end

  describe "new" do
    test "returns error when source :directory is not passed or present in settings" do
      # Ensure clean state - no project should be set in Application environment
      Services.Globals.put_env(:fnord, :project, nil)

      assert {:error, :project_not_set} = Cmd.Index.new(%{project: "test_project"})
    end

    test "succeeds when source :directory is passed" do
      # Create a temp dir to be our source :directory
      {:ok, tmp_dir} = tmpdir()

      raises_error =
        try do
          Cmd.Index.new(%{project: "test_project", directory: tmp_dir})
          false
        rescue
          e ->
            IO.inspect(e, label: "An unexpected error was raised")
            true
        end

      refute raises_error
    end

    test "succeeds when source :directory is in settings" do
      # Create a new project in a temp dir with saved settings
      project = mock_project("test_project")

      raises_error =
        try do
          Cmd.Index.new(%{project: project.name})
          false
        rescue
          e ->
            IO.inspect(e, label: "An unexpected error was raised")
            true
        end

      refute raises_error
    end
  end

  describe "root persistence" do
    setup do
      # Setup mock project
      project = mock_git_project("test_project")

      # Create a worktree
      {:ok, tmp} = tmpdir()

      System.cmd("git", ["worktree", "add", "-b", "some-feature", tmp],
        cd: project.source_root,
        stderr_to_stdout: true
      )

      {:ok, project: project, worktree: tmp}
    end

    test "transient override + run_as_tool_call does NOT change settings.json root", %{
      project: project,
      worktree: worktree
    } do
      Settings.set_project_root_override(worktree)
      Cmd.Index.run_as_tool_call(%{project: project.name, yes: true, quiet: true})
      persisted = Settings.new() |> Settings.get_project_data(project.name) |> Map.get("root")
      assert persisted == project.source_root
    end

    test "transient override + run/3 does NOT change settings.json root", %{
      project: project,
      worktree: worktree
    } do
      capture_all(fn ->
        Settings.set_project_root_override(worktree)
        Cmd.Index.run(%{project: project.name, yes: true, quiet: true}, [], [])
        persisted = Settings.new() |> Settings.get_project_data(project.name) |> Map.get("root")
        assert persisted == project.source_root
      end)
    end

    test "explicit --dir DOES persist new root", %{project: project} do
      # Create a temp dir for explicit --dir
      {:ok, tmp} = tmpdir()
      # Pass yes: true and quiet: true to bypass prompts
      {:ok, idx} = Cmd.Index.new(%{project: project.name, directory: tmp, yes: true, quiet: true})
      Cmd.Index.perform_task({:ok, idx})

      persisted =
        Settings.new()
        |> Settings.get_project_data(project.name)
        |> Map.get("root")

      assert persisted == Path.expand(tmp)
    end
  end
end
