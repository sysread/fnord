defmodule Cmd.Ask.WorktreeTest do
  # async: false - Cmd.Ask.run boots ad-hoc GenServers (Services.Conversation,
  # the background indexers) whose init code calls Mox-backed facades; those
  # processes are outside private-mode ownership, so this file needs global
  # Mox.
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("ask_worktree_test")
    {:ok, project: project}
  end

  setup do
    # The repo this suite runs from IS a git worktree, so the real GitCli
    # would trip ask's worktree-mismatch detection. The git layer is scripted
    # per test through the facade mocks, which pass through to the real
    # implementation for anything not explicitly stubbed.
    mock_git_cli()
    mock_git_worktree()
    mock_git_review()
    Mox.stub(GitCli.Mock, :is_worktree?, fn -> false end)
    Mox.stub(GitCli.Mock, :is_git_repo?, fn -> false end)
    :ok
  end

  # Cans the coordinator (and the ConversationIndexer's summary agent) at the
  # agent-dispatch seam; the real Services.Conversation server and store run
  # underneath. Sends {:coordinator, opts} to the test for each session
  # cycle so tests can count response cycles.
  defp canned_coordinator() do
    test_pid = self()

    canned_agent(fn
      AI.Agent.Coordinator, args ->
        send(test_pid, {:coordinator, args})
        {:ok, %{usage: 42, context: 42, last_response: "How now brown bureaucrat?"}}

      AI.Agent.ConversationSummary, _args ->
        {:ok, "test summary"}
    end)
  end

  # Seeds a real conversation file carrying worktree metadata, the state a
  # prior `ask --edit` session would have persisted.
  defp seed_worktree_conversation(worktree_meta) do
    {:ok, conv} =
      Store.Project.Conversation.new()
      |> Store.Project.Conversation.write(%{
        messages: [AI.Util.user_msg("earlier question")],
        metadata: %{worktree: worktree_meta},
        memory: [],
        tasks: %{}
      })

    conv
  end

  test "valid --worktree is applied" do
    canned_coordinator()

    assert Settings.get_project_root_override() == nil

    {:ok, dir} = tmpdir()

    {stdout, _stderr} =
      capture_all(fn ->
        assert :ok = Cmd.Ask.run(%{worktree: dir, question: "hello"}, [], [])
      end)

    assert Settings.get_project_root_override() == dir
    assert stdout =~ "How now brown bureaucrat?"
  end

  test "invalid --worktree errors early and leaves no override" do
    assert Settings.get_project_root_override() == nil
    bad = "/nope"

    capture_all(fn ->
      assert {:error, :invalid_worktree} =
               Cmd.Ask.run(%{worktree: bad, question: "hello"}, [], [])
    end)

    assert Settings.get_project_root_override() == nil
  end

  test "explicit rejected --worktree restores the stored worktree override" do
    canned_coordinator()
    {:ok, explicit_dir} = tmpdir()
    stored_dir = Path.join(Settings.get_user_home(), "stored-conversation-worktree")

    conv =
      seed_worktree_conversation(%{path: stored_dir, branch: "feature", base_branch: "main"})

    capture_all(fn ->
      assert {:error, {:conversation_worktree_exists, ^stored_dir}} =
               Cmd.Ask.run(
                 %{worktree: explicit_dir, question: "hello", follow: conv.id},
                 [],
                 []
               )
    end)

    assert Settings.get_project_root_override() == stored_dir
  end

  test "missing stored worktree is recreated without reinterpreting --worktree" do
    canned_coordinator()
    dir = Path.join(Settings.get_user_home(), "missing-conversation-worktree")

    conv = seed_worktree_conversation(%{path: dir, branch: "feature", base_branch: "main"})

    test_pid = self()

    Mox.stub(GitCli.Worktree.Mock, :recreate_conversation_worktree, fn "ask_worktree_test",
                                                                       conv_id,
                                                                       meta ->
      assert conv_id == conv.id
      assert meta.path == dir
      assert meta.branch == "feature"
      assert meta.base_branch == "main"
      send(test_pid, :recreate_called)
      File.mkdir_p!(dir)
      {:ok, %{path: dir, branch: "feature", base_branch: "main"}}
    end)

    assert Settings.get_project_root_override() == nil

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", edit: true, follow: conv.id}, [], [])
    end)

    assert_received :recreate_called
    assert Settings.get_project_root_override() == dir
  end

  test "conversation without a worktree binds an explicit existing --worktree" do
    canned_coordinator()
    {:ok, dir} = tmpdir()

    assert Settings.get_project_root_override() == nil

    {stdout, _stderr} =
      capture_all(fn ->
        assert :ok = Cmd.Ask.run(%{question: "Q", worktree: dir}, [], [])
      end)

    assert Settings.get_project_root_override() == dir

    # The path-only association is persisted to the saved conversation, so
    # the next --follow reattaches to the same worktree.
    assert [_, conv_id] = Regex.run(~r/Conversation saved with ID (\S+)/, stdout)

    {:ok, data} =
      conv_id
      |> Store.Project.Conversation.new()
      |> Store.Project.Conversation.read()

    meta = Map.get(data.metadata, :worktree) || Map.get(data.metadata, "worktree")
    assert GitCli.Worktree.normalize_worktree_meta(meta).path == dir
  end

  # Regression: when a conversation's stored worktree metadata has nil
  # branch/base_branch (the shape written for a path-only --worktree), end-of-
  # session cleanup previously crashed. maybe_discard_empty_worktree fed nil
  # branch/base_branch to GitCli.Worktree.diff_from_fork_point/3, which is
  # guarded on is_binary/1 for both and raised FunctionClauseError.
  test "fnord-managed worktree with nil branch metadata does not crash cleanup" do
    canned_coordinator()
    {:ok, dir} = tmpdir()
    test_pid = self()

    conv = seed_worktree_conversation(%{path: dir, branch: nil, base_branch: nil})

    Mox.stub(GitCli.Worktree.Mock, :fnord_managed?, fn _project, ^dir -> true end)
    Mox.stub(GitCli.Worktree.Mock, :has_uncommitted_changes?, fn ^dir -> false end)

    # diff_from_fork_point must NOT be called with nil branch/base_branch.
    # If the guard regresses, the sentinel reports it and the refute below
    # flunks the test.
    Mox.stub(GitCli.Worktree.Mock, :diff_from_fork_point, fn _root, _branch, _base ->
      send(test_pid, :diff_from_fork_point_called)
      {:ok, ""}
    end)

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", follow: conv.id}, [], [])
    end)

    refute_received :diff_from_fork_point_called
  end

  # Regression: in an interactive session, pre-merge validation failure only
  # propagates to do_worktree_review when the user answered "no" to the
  # "Merge anyway despite validation failure?" prompt. The fix cycle
  # previously ran unsolicited with yes: true hardcoded, reversing user
  # intent and silently elevating the approval policy. Interactive decline
  # must now short-circuit to :unmerged with no extra get_response call.
  test "interactive pre-merge decline does not trigger auto-approved fix cycle" do
    canned_coordinator()
    {:ok, dir} = tmpdir()

    conv = seed_worktree_conversation(%{path: dir, branch: "fnord-conv-1", base_branch: "main"})

    Mox.stub(GitCli.Worktree.Mock, :fnord_managed?, fn _project, ^dir -> true end)
    Mox.stub(GitCli.Worktree.Mock, :has_uncommitted_changes?, fn ^dir -> false end)
    Mox.stub(GitCli.Worktree.Mock, :commit_all, fn ^dir, _ -> {:error, :nothing_to_commit} end)
    Mox.stub(GitCli.Worktree.Mock, :has_changes_to_merge?, fn _, _, _, _ -> true end)

    # Non-empty diff: the worktree has real work, so it is not discarded as
    # empty before the review flow runs.
    Mox.stub(GitCli.Worktree.Mock, :diff_from_fork_point, fn _root, "fnord-conv-1", "main" ->
      {:ok, "+ real work"}
    end)

    Mox.stub(GitCli.Worktree.Review.Mock, :interactive_review, fn _root, meta, _opts ->
      assert meta.path == dir
      {:validation_failed, :pre_merge, "rule X failed"}
    end)

    {_stdout, stderr} =
      capture_all(fn ->
        assert :ok = Cmd.Ask.run(%{question: "Q", edit: true, follow: conv.id}, [], [])
      end)

    assert stderr =~ "Worktree changes were not merged"

    # Only the initial response cycle; no unsolicited fix cycle.
    assert_received {:coordinator, _}
    refute_received {:coordinator, _}
  end
end
