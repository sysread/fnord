defmodule Cmd.WorktreesTest do
  use Fnord.TestCase, async: true

  # ---------------------------------------------------------------------------
  # These tests script git state through the GitCli facade mocks while the
  # command logic, conversation store, and metadata normalization run real:
  # conversations are written to the per-test store (read back with string
  # keys, exercising the JSON round-trip the command actually sees), and only
  # the worktree/review git operations are canned.
  # ---------------------------------------------------------------------------

  setup do
    project = mock_project("demo")

    mock_git_cli()
    mock_git_worktree()
    mock_git_review()

    {:ok, project: project}
  end

  # Writes a real conversation carrying worktree metadata, returning the
  # conversation struct. Metadata round-trips through JSON, so the command
  # reads it back string-keyed and normalizes - same shape as production.
  defp write_conversation(conv_id, metadata) do
    conv = Store.Project.Conversation.new(conv_id)

    {:ok, _} =
      Store.Project.Conversation.write(conv, %{
        messages: [AI.Util.user_msg("hi"), AI.Util.assistant_msg("hello")],
        metadata: metadata,
        memories: []
      })

    conv
  end

  describe "worktrees command" do
    test "lists fnord-managed worktrees as a table" do
      Mox.stub(GitCli.Worktree.Mock, :project_root, fn -> {:ok, "/repo"} end)

      wt_root = GitCli.Worktree.default_root("demo")

      Mox.stub(GitCli.Worktree.Mock, :list_raw, fn "/repo" ->
        {:ok,
         [
           %{
             path: Path.join(wt_root, "conv-1"),
             branch: "fnord-conv-1",
             merge_status: :ahead,
             size: 2048
           },
           %{
             path: "/repo",
             branch: "main",
             merge_status: :unknown,
             size: 0
           }
         ]}
      end)

      Mox.stub(GitCli.Worktree.Mock, :enrich, fn _root, entry -> entry end)
      Mox.stub(GitCli.Worktree.Mock, :has_uncommitted_changes?, fn _path -> false end)

      output =
        capture_io(fn ->
          assert :ok == Cmd.Worktrees.run(%{}, [:list], [])
        end)

      # The managed worktree should appear; the main repo entry should not
      assert output =~ "conv-1"
      assert output =~ "fnord-conv-1"
      assert output =~ "ahead"
      refute output =~ "/repo"
    end

    test "lists no worktrees when none are fnord-managed" do
      Mox.stub(GitCli.Worktree.Mock, :project_root, fn -> {:ok, "/repo"} end)

      Mox.stub(GitCli.Worktree.Mock, :list_raw, fn "/repo" ->
        {:ok,
         [
           %{path: "/repo", branch: "main", merge_status: :unknown, size: 0}
         ]}
      end)

      assert :ok == Cmd.Worktrees.run(%{}, [:list], [])
    end

    test "creates a local worktree" do
      Mox.stub(GitCli.Worktree.Mock, :create, fn "demo", "conv-1", "feat" ->
        {:ok, %{path: "/repo/wt-feat"}}
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1", branch: "feat"}, [:create], [])
    end

    test "deletes a worktree by conversation id" do
      conv =
        write_conversation("conv-1", %{
          worktree: %{path: "/tmp/wt", branch: "fnord-conv-1", base_branch: "main"}
        })

      Mox.stub(GitCli.Worktree.Mock, :project_root, fn -> {:ok, "/repo"} end)

      Mox.stub(GitCli.Worktree.Mock, :diff_against_base, fn "/repo", "fnord-conv-1", "main" ->
        {:ok, ""}
      end)

      Mox.stub(GitCli.Worktree.Mock, :delete, fn "/repo", "/tmp/wt" -> {:ok, :ok} end)
      Mox.stub(GitCli.Worktree.Mock, :delete_branch, fn "/repo", "fnord-conv-1" -> {:ok, :ok} end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:delete], [])

      # The cleanup ran against the real store: worktree metadata is gone.
      {:ok, data} = Store.Project.Conversation.read(conv)
      refute Map.has_key?(data.metadata, :worktree)
      refute Map.has_key?(data.metadata, "worktree")
    end

    test "does not delete the branch when worktree removal fails" do
      write_conversation("conv-1", %{
        worktree: %{path: "/tmp/wt", branch: "fnord-conv-1", base_branch: "main"}
      })

      test_pid = self()

      Mox.stub(GitCli.Worktree.Mock, :project_root, fn -> {:ok, "/repo"} end)

      Mox.stub(GitCli.Worktree.Mock, :diff_against_base, fn "/repo", "fnord-conv-1", "main" ->
        {:ok, ""}
      end)

      Mox.stub(GitCli.Worktree.Mock, :delete, fn "/repo", "/tmp/wt" -> {:error, :git_failed} end)
      Mox.stub(GitCli.Worktree.Mock, :has_uncommitted_changes?, fn "/tmp/wt" -> true end)

      Mox.stub(GitCli.Worktree.Mock, :force_delete, fn "/repo", "/tmp/wt" ->
        {:error, :git_failed}
      end)

      # Sentinel: branch deletion must not be attempted when worktree
      # deletion fails - any call is reported back and flunked below.
      Mox.stub(GitCli.Worktree.Mock, :delete_branch, fn _, _ ->
        send(test_pid, :branch_delete_attempted)
        {:ok, :ok}
      end)

      {stdout, _stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:delete], [])
        end)

      assert stdout =~ "Force delete anyway?"
      refute_received :branch_delete_attempted
    end

    test "merges a worktree by conversation id via interactive review" do
      write_conversation("conv-1", %{
        worktree: %{path: "/tmp/wt", branch: "fnord-conv-1", base_branch: "main"}
      })

      test_pid = self()

      Mox.stub(GitCli.Worktree.Mock, :project_root, fn -> {:ok, "/repo"} end)

      Mox.stub(GitCli.Worktree.Review.Mock, :interactive_review, fn "/repo", meta, _opts ->
        send(test_pid, {:review_meta, meta})
        :ok
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:merge], [])

      assert_received {:review_meta, meta}
      assert meta.path == "/tmp/wt"
      assert meta.branch == "fnord-conv-1"
    end

    test "views a worktree diff using the conversation worktree path even when override state is stale" do
      {:ok, path} = tmpdir()

      write_conversation("conv-1", %{
        worktree: %{path: path, branch: "fnord-conv-1", base_branch: "main"}
      })

      Settings.set_project_root_override("/definitely/not/a/repo")
      on_exit(fn -> Settings.set_project_root_override(nil) end)

      # The repo root must be resolved from the worktree path itself, not the
      # (stale) override - the pattern match on ^path enforces it.
      Mox.stub(GitCli.Mock, :repo_root_at, fn ^path -> {:ok, "/repo"} end)

      Mox.stub(GitCli.Worktree.Mock, :diff_from_fork_point, fn "/repo", "fnord-conv-1", "main" ->
        {:ok, ""}
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:view], [])
    end

    test "views a worktree diff by discovering a fnord-managed worktree when conversation metadata is empty" do
      write_conversation("conv-1", %{})

      path = Path.join(GitCli.Worktree.default_root("demo"), "conv-1")
      File.mkdir_p!(path)

      Mox.stub(GitCli.Worktree.Mock, :project_root, fn -> {:ok, "/repo"} end)

      # fnord_managed? passes through to the real implementation: the first
      # entry sits under the default root and is selected; the second does not.
      Mox.stub(GitCli.Worktree.Mock, :list_raw, fn "/repo" ->
        {:ok,
         [
           %{
             path: path,
             branch: "feature-branch",
             base_branch: "main",
             merge_status: :ahead,
             size: 0
           },
           %{
             path: "/outside/demo/conv-1",
             branch: "other-branch",
             base_branch: "main",
             merge_status: :ahead,
             size: 0
           }
         ]}
      end)

      Mox.stub(GitCli.Mock, :repo_root_at, fn ^path -> {:ok, "/repo"} end)

      Mox.stub(GitCli.Worktree.Mock, :diff_from_fork_point, fn "/repo",
                                                               "feature-branch",
                                                               "main" ->
        {:ok, ""}
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:view], [])
    end

    test "reports a missing worktree path when viewing a diff" do
      write_conversation("conv-1", %{
        worktree: %{path: "/tmp/missing-wt", branch: "fnord-conv-1", base_branch: "main"}
      })

      test_pid = self()

      Mox.stub(UI.Output.Mock, :log, fn level, msg ->
        send(test_pid, {:ui_log, level, IO.iodata_to_binary(msg)})
        :ok
      end)

      assert {:error, :missing_worktree_path} ==
               Cmd.Worktrees.run(%{conversation: "conv-1"}, [:view], [])

      assert_received {:ui_log, :error, msg}
      assert msg =~ "Worktree path does not exist or is inaccessible"
    end

    test "reports a non-repo directory when viewing a diff" do
      {:ok, path} = tmpdir()

      write_conversation("conv-1", %{
        worktree: %{path: path, branch: "fnord-conv-1", base_branch: "main"}
      })

      Mox.stub(GitCli.Mock, :repo_root_at, fn ^path -> {:error, :not_a_repo} end)

      test_pid = self()

      Mox.stub(UI.Output.Mock, :log, fn level, msg ->
        send(test_pid, {:ui_log, level, IO.iodata_to_binary(msg)})
        :ok
      end)

      assert {:error, :not_a_repo} ==
               Cmd.Worktrees.run(%{conversation: "conv-1"}, [:view], [])

      assert_received {:ui_log, :error, msg}
      assert msg =~ "Worktree path is not inside a git repository"
    end
  end
end
