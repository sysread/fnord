defmodule Cmd.IndexTest do
  use Fnord.TestCase, async: false

  setup do
    set_config(workers: 1)
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
      # Create a conversation for the project
      conversation = Store.Project.Conversation.new("conv1", project)
      messages = [AI.Util.system_msg("Hello")]
      {:ok, _} = Store.Project.Conversation.write(conversation, %{messages: messages, metadata: %{}, memories: []})

      # Stub the indexer implementation
      Services.Globals.put_env(:fnord, :indexer, StubIndexer)

      # Run the indexing process
      Cmd.Index.run(%{project: project.name, yes: true, quiet: true}, [], [])

      # Re-fetch project to check status
      {:ok, project} = Store.get_project(project.name)

      # Assert conversation index status
      status = Store.Project.ConversationIndex.index_status(project)
      assert status.new == []
      assert status.stale == []

      # Assert embeddings have been indexed
      embeddings_list =
        Store.Project.ConversationIndex.all_embeddings(project)
        |> Enum.into([])

      assert Enum.any?(embeddings_list, fn {id, _emb, _meta} -> id == conversation.id end)
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
