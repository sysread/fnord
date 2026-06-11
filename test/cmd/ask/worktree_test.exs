defmodule Cmd.Ask.WorktreeTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("ask_worktree_test")
    {:ok, project: project}
  end

  setup do
    # Services.Conversation stays mecked: these tests script the conversation
    # server's responses (and in one case its absence of a worktree) without
    # running a real session. The git layer is scripted per test through the
    # GitCli facade mocks, which pass through to the real implementation for
    # anything not explicitly stubbed.
    safe_meck_new(Services.Conversation, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> safe_meck_unload(Services.Conversation) end)

    mock_git_worktree()
    mock_git_review()

    :ok
  end

  test "valid --worktree is applied" do
    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok,
       %{
         usage: 42,
         context: 42,
         last_response: "How now brown bureaucrat?"
       }}
    end)

    assert Settings.get_project_root_override() == nil

    {:ok, dir} = tmpdir()

    {_stdout, _stderr} =
      capture_all(fn ->
        assert :ok =
                 Cmd.Ask.run(
                   %{
                     worktree: dir,
                     question: "hello"
                   },
                   [],
                   []
                 )
      end)

    assert Settings.get_project_root_override() == dir
  end

  test "invalid --worktree errors early and leaves no override" do
    assert Settings.get_project_root_override() == nil
    bad = "/nope"

    assert {:error, :invalid_worktree} =
             Cmd.Ask.run(
               %{
                 worktree: bad,
                 question: "hello"
               },
               [],
               []
             )

    assert Settings.get_project_root_override() == nil
  end

  test "explicit --worktree is rejected when the conversation already has one" do
    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{worktree: %{path: "/tmp/existing", branch: "feature", base_branch: "main"}}
    end)

    assert {:error, :invalid_worktree} =
             Cmd.Ask.run(
               %{
                 worktree: "/tmp/another",
                 question: "hello"
               },
               [],
               []
             )
  end

  test "explicit rejected --worktree restores the stored worktree override" do
    {:ok, explicit_dir} = tmpdir()
    stored_dir = Path.join(Settings.get_user_home(), "stored-conversation-worktree")

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{worktree: %{path: stored_dir, branch: "feature", base_branch: "main"}}
    end)

    assert {:error, {:conversation_worktree_exists, ^stored_dir}} =
             Cmd.Ask.run(
               %{
                 worktree: explicit_dir,
                 question: "hello"
               },
               [],
               []
             )

    assert Settings.get_project_root_override() == stored_dir
  end

  test "missing stored worktree is recreated without reinterpreting --worktree" do
    dir = Path.join(Settings.get_user_home(), "missing-conversation-worktree")
    meta = %{path: dir, branch: "feature", base_branch: "main"}

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{worktree: meta}
    end)

    :meck.expect(Services.Conversation, :get_id, fn _pid -> "conv-1" end)

    test_pid = self()

    Mox.stub(GitCli.Worktree.Mock, :recreate_conversation_worktree, fn "ask_worktree_test",
                                                                       "conv-1",
                                                                       ^meta ->
      send(test_pid, :recreate_called)
      File.mkdir_p!(dir)
      {:ok, %{path: dir, branch: "feature", base_branch: "main"}}
    end)

    :meck.expect(Services.Conversation, :upsert_conversation_meta, fn _pid, update ->
      assert update == %{worktree: %{path: dir, branch: "feature", base_branch: "main"}}
      :ok
    end)

    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    assert Settings.get_project_root_override() == nil

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", edit: true}, [], [])
    end)

    assert_received :recreate_called
    assert Settings.get_project_root_override() == dir
  end

  test "conversation without a worktree binds an explicit existing --worktree" do
    {:ok, dir} = tmpdir()

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{}
    end)

    :meck.expect(Services.Conversation, :upsert_conversation_meta, fn _pid, meta ->
      assert meta == %{worktree: %{path: dir, branch: nil, base_branch: nil}}
      :ok
    end)

    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    assert Settings.get_project_root_override() == nil

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", worktree: dir}, [], [])
    end)

    assert Settings.get_project_root_override() == dir
  end

  # Regression: when a conversation's stored worktree metadata has nil
  # branch/base_branch (the shape written for a path-only --worktree), end-of-
  # session cleanup previously crashed. maybe_discard_empty_worktree fed nil
  # branch/base_branch to GitCli.Worktree.diff_from_fork_point/3, which is
  # guarded on is_binary/1 for both and raised FunctionClauseError.
  test "fnord-managed worktree with nil branch metadata does not crash cleanup" do
    {:ok, dir} = tmpdir()
    stored_meta = %{path: dir, branch: nil, base_branch: nil}
    test_pid = self()

    Mox.stub(GitCli.Worktree.Mock, :fnord_managed?, fn _project, ^dir -> true end)
    Mox.stub(GitCli.Worktree.Mock, :has_uncommitted_changes?, fn ^dir -> false end)
    Mox.stub(GitCli.Worktree.Mock, :has_changes_to_merge?, fn _, _, _, _ -> false end)

    # diff_from_fork_point must NOT be called with nil branch/base_branch.
    # If the guard regresses, the sentinel reports it and the refute below
    # flunks the test.
    Mox.stub(GitCli.Worktree.Mock, :diff_from_fork_point, fn _root, _branch, _base ->
      send(test_pid, :diff_from_fork_point_called)
      {:ok, ""}
    end)

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{worktree: stored_meta}
    end)

    :meck.expect(Services.Conversation, :upsert_conversation_meta, fn _pid, _meta -> :ok end)

    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q"}, [], [])
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
    {:ok, dir} = tmpdir()
    meta = %{path: dir, branch: "fnord-conv-1", base_branch: "main"}

    Mox.stub(GitCli.Worktree.Mock, :fnord_managed?, fn _project, ^dir -> true end)
    Mox.stub(GitCli.Worktree.Mock, :has_uncommitted_changes?, fn ^dir -> false end)
    Mox.stub(GitCli.Worktree.Mock, :has_changes_to_merge?, fn _, _, _, _ -> true end)
    Mox.stub(GitCli.Worktree.Mock, :commit_all, fn _, _ -> {:error, :nothing_to_commit} end)

    Mox.stub(GitCli.Worktree.Review.Mock, :interactive_review, fn _root, ^meta, _opts ->
      {:validation_failed, :pre_merge, "rule X failed"}
    end)

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{worktree: meta}
    end)

    :meck.expect(Services.Conversation, :upsert_conversation_meta, fn _pid, _meta -> :ok end)
    :meck.expect(Services.Conversation, :append_msg, fn _msg, _pid -> :ok end)

    test_pid = self()

    :meck.expect(Services.Conversation, :get_response, fn _pid, opts ->
      send(test_pid, {:get_response, opts})
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", edit: true}, [], [])
    end)

    # Only the initial response cycle; no unsolicited fix cycle.
    assert_received {:get_response, _}
    refute_received {:get_response, _}
  end
end
