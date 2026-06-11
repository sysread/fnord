defmodule Cmd.AskTest do
  # async: false - Cmd.Ask.run boots ad-hoc GenServers (Services.Conversation,
  # the background indexers) whose init code calls Mox-backed facades. Those
  # processes are not in the instance registry, so private-mode allowances
  # cannot reach them; this file needs global Mox.
  use Fnord.TestCase, async: false

  setup do
    Services.Globals.delete_env(:fnord, :auto_policy)
    {:ok, project: mock_project("ask_proj")}
  end

  setup do
    # The repo this suite runs from IS a git worktree, so the real GitCli
    # would trip ask's worktree-mismatch detection. Script git state through
    # the facades: plain checkout, not a git repo (the commit-indexer tests
    # override is_git_repo? to exercise that branch).
    mock_git_cli()
    mock_git_worktree()
    mock_git_review()
    Mox.stub(GitCli.Mock, :is_worktree?, fn -> false end)
    Mox.stub(GitCli.Mock, :is_git_repo?, fn -> false end)
    :ok
  end

  # Cans the coordinator at the agent-dispatch seam. Everything below the
  # dispatcher - the real Services.Conversation server, conversation
  # persistence, Services.Task, Memory - runs for real against the per-test
  # store. The ConversationIndexer summarizes pre-existing conversations
  # through the same seam, so --follow tests also need that agent canned.
  defp canned_coordinator(response \\ "hello") do
    canned_agent(fn
      AI.Agent.Coordinator, _args ->
        {:ok, %{usage: 1, context: 2, last_response: response}}

      AI.Agent.ConversationSummary, _args ->
        {:ok, "test summary"}
    end)
  end

  # UI.error/info land on UI.Output.log, which the default TestStub routes to
  # Logger - invisible to capture_all. Mirror log traffic onto stderr so the
  # assertions below see it, the same surface the user does.
  defp redirect_ui_log_to_stderr() do
    Mox.stub(UI.Output.Mock, :log, fn _level, msg -> IO.puts(:stderr, msg) end)
  end

  # Seeds a real conversation file carrying worktree metadata, the state a
  # prior `ask --edit` session would have persisted. Following it is the
  # honest path into the merge-review flow.
  defp seed_worktree_conversation(worktree_dir) do
    {:ok, conv} =
      Store.Project.Conversation.new()
      |> Store.Project.Conversation.write(%{
        messages: [AI.Util.user_msg("earlier question")],
        metadata: %{worktree: %{path: worktree_dir, branch: "feat", base_branch: "main"}},
        memory: [],
        tasks: %{}
      })

    conv
  end

  test "default auto policy is deny after 180_000 ms when no flags provided" do
    opts = %{}
    # Apply the default policy
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:deny, 180_000}
  end

  test "auto deny override uses provided seconds" do
    opts = %{auto_deny_after: 5}
    # Validate flags first
    assert :ok == apply(Cmd.Ask, :validate_auto, [opts])
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:deny, 5_000}
  end

  test "auto approve override uses provided seconds" do
    opts = %{auto_approve_after: 2}
    assert :ok == apply(Cmd.Ask, :validate_auto, [opts])
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:approve, 2_000}
  end

  test "mutually exclusive auto flags returns error" do
    opts = %{auto_approve_after: 1, auto_deny_after: 2}
    assert {:error, _msg} = apply(Cmd.Ask, :validate_auto, [opts])
  end

  test "invalid auto flag values return error" do
    assert {:error, _} = apply(Cmd.Ask, :validate_auto, [%{auto_approve_after: 0}])
    assert {:error, _} = apply(Cmd.Ask, :validate_auto, [%{auto_deny_after: -1}])
  end

  describe "run/3 crash propagation" do
    test "a coordinator crash propagates instead of becoming a fake result" do
      canned_agent(fn AI.Agent.Coordinator, _args -> raise "boom" end)

      # The crash happens inside the Task that AI.Agent.get_response wraps
      # around dispatch; the task link delivers it to this process, where
      # trapping converts it into the Task.await exit we can assert on.
      Process.flag(:trap_exit, true)

      capture_all(fn ->
        assert {{%RuntimeError{message: "boom"}, _stack}, _mfa} =
                 catch_exit(Cmd.Ask.run(%{question: "whoops?"}, [], []))
      end)
    end
  end

  describe "run/3 missing conversations" do
    test "reports the missing fork conversation id" do
      redirect_ui_log_to_stderr()

      {_stdout, stderr} =
        capture_all(fn ->
          assert {:error, :conversation_not_found} =
                   Cmd.Ask.run(%{question: "hello", fork: "fork-404"}, [], [])
        end)

      assert stderr =~ "Conversation ID fork-404 not found"
    end
  end

  describe "run/3 output persistence" do
    test "saves the response to the outputs store with --save" do
      canned_coordinator("# Title: My Answer\n\nthe answer is 42")

      {_stdout, _stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello", save: true}, [], [])
        end)

      assert [path] = Path.wildcard(Path.join(Outputs.outputs_dir("ask_proj"), "*.md"))
      assert Path.basename(path) =~ "my-answer"
      assert File.read!(path) =~ "the answer is 42"
    end

    test "logs a save failure instead of crashing when output persistence fails" do
      canned_coordinator()
      redirect_ui_log_to_stderr()

      # Real failure injection: an unwritable outputs dir denies the lock
      # file, so Outputs.save surfaces an error instead of writing.
      dir = Outputs.outputs_dir("ask_proj")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o555)
      on_exit(fn -> File.chmod(dir, 0o755) end)

      {_stdout, stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello", save: true}, [], [])
        end)

      assert stderr =~ "Failed to save output:"
      assert stderr =~ "(no file changes during this session)"
    end
  end

  describe "run/3 clipboard reporting" do
    test "reports the conversation id as copied to the clipboard" do
      canned_coordinator()

      {stdout, stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello"}, [], [])
        end)

      assert stderr =~ "(no file changes during this session)"
      assert stdout =~ "Conversation saved with ID"
      assert stdout =~ "copied to clipboard"
    end

    test "omits clipboard success text when copying the conversation id fails" do
      canned_coordinator()
      Mox.stub(Util.Clipboard.Mock, :copy, fn _text -> {:error, :unavailable} end)

      {stdout, stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello"}, [], [])
        end)

      assert stderr =~ "(no file changes during this session)"
      assert stdout =~ "Conversation saved with ID"
      refute stdout =~ "copied to clipboard"
    end
  end

  describe "run/3 merged worktree reporting" do
    setup %{project: project} do
      {:ok, worktree_dir} = tmpdir()
      conv = seed_worktree_conversation(worktree_dir)
      canned_coordinator()

      # Script the worktree git plumbing: fnord-managed worktree with real
      # work to merge. The review outcome itself is per-test.
      Mox.stub(GitCli.Worktree.Mock, :fnord_managed?, fn "ask_proj", ^worktree_dir -> true end)
      Mox.stub(GitCli.Worktree.Mock, :has_uncommitted_changes?, fn ^worktree_dir -> true end)

      Mox.stub(GitCli.Worktree.Mock, :commit_all, fn ^worktree_dir, _label ->
        {:error, :nothing_to_commit}
      end)

      root = project.source_root

      Mox.stub(GitCli.Worktree.Mock, :has_changes_to_merge?, fn ^root,
                                                                ^worktree_dir,
                                                                "feat",
                                                                "main" ->
        true
      end)

      {:ok, conv: conv, worktree_dir: worktree_dir, root: root}
    end

    test "clears the final worktree summary after interactive merge cleanup", ctx do
      %{conv: conv, worktree_dir: worktree_dir, root: root} = ctx

      Mox.stub(GitCli.Worktree.Review.Mock, :interactive_review, fn ^root, meta, _opts ->
        assert meta.path == worktree_dir
        assert meta.branch == "feat"
        assert meta.base_branch == "main"
        {:cleaned_up, {"aaa000", "abc123"}, :interactive}
      end)

      Mox.stub(GitCli.Worktree.Mock, :log_oneline, fn ^root, "aaa000", "abc123" ->
        ["abc123 add feature file"]
      end)

      {stdout, stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello", follow: conv.id, edit: true}, [], [])
        end)

      assert stderr =~ "Worktree changes merged successfully"
      assert stderr =~ "abc123 add feature file"
      assert Settings.get_project_root_override() == nil
      refute stdout =~ "Worktree path:"

      # The merge cleanup also strips the worktree association from the
      # persisted conversation, so the next --follow starts fresh.
      {:ok, data} = Store.Project.Conversation.read(conv)
      refute Map.has_key?(data.metadata, :worktree)
      refute Map.has_key?(data.metadata, "worktree")
    end

    test "notes that --yes triggered auto-merge and clears the worktree summary", ctx do
      %{conv: conv, worktree_dir: worktree_dir, root: root} = ctx

      Mox.stub(GitCli.Worktree.Review.Mock, :auto_merge, fn ^root, meta, _opts ->
        assert meta.path == worktree_dir
        assert meta.branch == "feat"
        assert meta.base_branch == "main"
        {:cleaned_up, {"bbb000", "def456"}, :auto}
      end)

      Mox.stub(GitCli.Worktree.Mock, :log_oneline, fn ^root, "bbb000", "def456" ->
        ["def456 auto feature"]
      end)

      {stdout, stderr} =
        capture_all(fn ->
          assert :ok ==
                   Cmd.Ask.run(
                     %{question: "hello", follow: conv.id, edit: true, yes: true},
                     [],
                     []
                   )
        end)

      assert stderr =~ "auto-merged because --yes was specified"
      assert stderr =~ "def456 auto feature"
      assert Settings.get_project_root_override() == nil
      refute stdout =~ "Worktree path:"
    end
  end

  describe "commit indexer startup" do
    # Services.CommitIndexer's init resolves its candidate list through the
    # commit-history enumeration on the GitCli facade. commit_shas is only
    # reachable through that scan, so the probe below observes the indexer
    # actually booting and scanning - not just the gating branch in Cmd.Ask.
    # (is_git_repo_at? would be a bad probe: the file-index scan consults it
    # too, via resolve_default_branch.)
    setup do
      canned_coordinator()
      test_pid = self()

      Mox.stub(GitCli.Mock, :commit_shas, fn _root, _ref ->
        send(test_pid, :commit_history_scanned)
        {:ok, []}
      end)

      :ok
    end

    test "starts the commit indexer in git repositories" do
      Mox.stub(GitCli.Mock, :is_git_repo?, fn -> true end)
      Mox.stub(GitCli.Mock, :is_git_repo_at?, fn _root -> true end)

      capture_all(fn ->
        assert :ok == Cmd.Ask.run(%{question: "hello"}, [], [])
      end)

      assert_received :commit_history_scanned
    end

    test "skips the commit indexer outside git repositories" do
      capture_all(fn ->
        assert :ok == Cmd.Ask.run(%{question: "hello"}, [], [])
      end)

      refute_received :commit_history_scanned
    end
  end
end
