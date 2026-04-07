defmodule Cmd.WorktreesTest do
  use Fnord.TestCase, async: false

  setup do
    :ok = safe_meck_new(GitCli.Worktree, [:passthrough])
    :ok = safe_meck_new(Store, [:passthrough])
    :ok = safe_meck_new(Store.Project.Conversation, [:passthrough])
    :ok = safe_meck_new(GitCli.Worktree.Review, [:passthrough])

    on_exit(fn ->
      safe_meck_unload(GitCli.Worktree)
      safe_meck_unload(Store)
      safe_meck_unload(Store.Project.Conversation)
      safe_meck_unload(GitCli.Worktree.Review)
    end)

    :ok
  end

  describe "worktrees command" do
    test "lists fnord-managed worktrees as a table" do
      project = %{name: "demo"}
      :meck.expect(Store, :get_project, fn -> {:ok, project} end)
      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)

      wt_root = GitCli.Worktree.default_root("demo")

      :meck.expect(GitCli.Worktree, :list, fn "/repo" ->
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

      :meck.expect(GitCli.Worktree, :has_uncommitted_changes?, fn _path -> false end)

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
      project = %{name: "demo"}
      :meck.expect(Store, :get_project, fn -> {:ok, project} end)
      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)

      :meck.expect(GitCli.Worktree, :list, fn "/repo" ->
        {:ok,
         [
           %{path: "/repo", branch: "main", merge_status: :unknown, size: 0}
         ]}
      end)

      assert :ok == Cmd.Worktrees.run(%{}, [:list], [])
    end

    test "creates a local worktree" do
      :meck.expect(Store, :get_project, fn -> {:ok, %{name: "demo"}} end)

      :meck.expect(GitCli.Worktree, :create, fn "demo", "conv-1", "feat" ->
        {:ok, %{path: "/repo/wt-feat"}}
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1", branch: "feat"}, [:create], [])
    end

    test "deletes a worktree by conversation id" do
      conv = %Store.Project.Conversation{
        id: "conv-1",
        project_home: "/tmp",
        store_path: "/tmp/conv-1.json"
      }

      meta = %{worktree: %{path: "/tmp/wt", branch: "fnord-conv-1", base_branch: "main"}}

      :meck.expect(Store.Project.Conversation, :new, fn "conv-1" -> conv end)

      :meck.expect(Store.Project.Conversation, :read, fn ^conv ->
        {:ok, %{metadata: meta, messages: [], memory: [], tasks: %{}}}
      end)

      :meck.expect(Store.Project.Conversation, :write, fn ^conv, _data -> {:ok, conv} end)
      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)

      :meck.expect(GitCli.Worktree, :diff_against_base, fn "/repo", "fnord-conv-1", "main" ->
        {:ok, ""}
      end)

      :meck.expect(GitCli.Worktree, :delete, fn "/repo", "/tmp/wt" -> {:ok, :ok} end)
      :meck.expect(GitCli.Worktree, :delete_branch, fn "/repo", "fnord-conv-1" -> {:ok, :ok} end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:delete], [])
    end

    test "does not delete the branch when worktree removal fails" do
      conv = %Store.Project.Conversation{
        id: "conv-1",
        project_home: "/tmp",
        store_path: "/tmp/conv-1.json"
      }

      meta = %{worktree: %{path: "/tmp/wt", branch: "fnord-conv-1", base_branch: "main"}}

      :meck.expect(Store.Project.Conversation, :new, fn "conv-1" -> conv end)

      :meck.expect(Store.Project.Conversation, :read, fn ^conv ->
        {:ok, %{metadata: meta, messages: [], memory: [], tasks: %{}}}
      end)

      :meck.expect(Store.Project.Conversation, :write, fn ^conv, _data -> {:ok, conv} end)
      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)

      :meck.expect(GitCli.Worktree, :diff_against_base, fn "/repo", "fnord-conv-1", "main" ->
        {:ok, ""}
      end)

      :meck.expect(GitCli.Worktree, :delete, fn "/repo", "/tmp/wt" -> {:error, :git_failed} end)
      :meck.expect(GitCli.Worktree, :has_uncommitted_changes?, fn "/tmp/wt" -> true end)

      :meck.expect(GitCli.Worktree, :force_delete, fn "/repo", "/tmp/wt" ->
        {:error, :git_failed}
      end)

      :meck.expect(GitCli.Worktree, :delete_branch, fn _, _ ->
        flunk("branch deletion should not be attempted when worktree deletion fails")
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:delete], [])
    end

    test "merges a worktree by conversation id via interactive review" do
      conv = %Store.Project.Conversation{
        id: "conv-1",
        project_home: "/tmp",
        store_path: "/tmp/conv-1.json"
      }

      :meck.expect(Store.Project.Conversation, :new, fn "conv-1" -> conv end)

      :meck.expect(Store.Project.Conversation, :read, fn ^conv ->
        {:ok,
         %{
           metadata: %{worktree: %{path: "/tmp/wt", branch: "fnord-conv-1", base_branch: "main"}}
         }}
      end)

      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)

      :meck.expect(GitCli.Worktree.Review, :interactive_review, fn "/repo", meta ->
        assert meta.path == "/tmp/wt"
        assert meta.branch == "fnord-conv-1"
        :ok
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:merge], [])
    end

    test "views a worktree diff using the conversation worktree path even when override state is stale" do
      conv = %Store.Project.Conversation{
        id: "conv-1",
        project_home: "/tmp",
        store_path: "/tmp/conv-1.json"
      }

      {:ok, path} = tmpdir()

      :meck.expect(Store.Project.Conversation, :new, fn "conv-1" -> conv end)

      :meck.expect(Store.Project.Conversation, :read, fn ^conv ->
        {:ok,
         %{
           metadata: %{worktree: %{path: path, branch: "fnord-conv-1", base_branch: "main"}}
         }}
      end)

      Settings.set_project_root_override("/definitely/not/a/repo")

      on_exit(fn ->
        Settings.set_project_root_override(nil)

        try do
          :meck.unload(System)
        catch
          _, _ -> :ok
        end
      end)

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "git", ["rev-parse", "--show-toplevel"], [cd: ^path, stderr_to_stdout: true] ->
          {"/repo\n", 0}

        command, args, opts ->
          :meck.passthrough([command, args, opts])
      end)

      :meck.expect(GitCli.Worktree, :diff_from_fork_point, fn "/repo", "fnord-conv-1", "main" ->
        {:ok, ""}
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:view], [])

      assert :meck.called(System, :cmd, [
               "git",
               ["rev-parse", "--show-toplevel"],
               [cd: path, stderr_to_stdout: true]
             ])

      assert :meck.validate(System)
    end

    test "views a worktree diff by discovering a fnord-managed worktree when conversation metadata is empty" do
      conv = %Store.Project.Conversation{
        id: "conv-1",
        project_home: "/tmp",
        store_path: "/tmp/conv-1.json"
      }

      path = Path.join(GitCli.Worktree.default_root("demo"), "conv-1")
      File.mkdir_p!(path)

      :meck.expect(Store, :get_project, fn -> {:ok, %{name: "demo"}} end)
      :meck.expect(Store.Project.Conversation, :new, fn "conv-1" -> conv end)
      :meck.expect(Store.Project.Conversation, :read, fn ^conv -> {:ok, %{metadata: %{}}} end)
      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)

      :meck.expect(GitCli.Worktree, :list, fn "/repo" ->
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

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "git", ["rev-parse", "--show-toplevel"], [cd: ^path, stderr_to_stdout: true] ->
          {"/repo\n", 0}

        command, args, opts ->
          :meck.passthrough([command, args, opts])
      end)

      :meck.expect(GitCli.Worktree, :diff_from_fork_point, fn "/repo", "feature-branch", "main" ->
        {:ok, ""}
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1"}, [:view], [])
    end

    test "reports a missing worktree path when viewing a diff" do
      conv = %Store.Project.Conversation{
        id: "conv-1",
        project_home: "/tmp",
        store_path: "/tmp/conv-1.json"
      }

      :meck.expect(Store.Project.Conversation, :new, fn "conv-1" -> conv end)

      :meck.expect(Store.Project.Conversation, :read, fn ^conv ->
        {:ok,
         %{
           metadata: %{
             worktree: %{path: "/tmp/missing-wt", branch: "fnord-conv-1", base_branch: "main"}
           }
         }}
      end)

      :meck.expect(UI, :error, fn message ->
        send(self(), {:ui_error, message})
        :ok
      end)

      assert {:error, :missing_worktree_path} ==
               Cmd.Worktrees.run(%{conversation: "conv-1"}, [:view], [])

      assert_receive {:ui_error, "Worktree path does not exist or is inaccessible"}
    end

    test "reports a non-repo directory when viewing a diff" do
      conv = %Store.Project.Conversation{
        id: "conv-1",
        project_home: "/tmp",
        store_path: "/tmp/conv-1.json"
      }

      {:ok, path} = tmpdir()

      :meck.expect(Store.Project.Conversation, :new, fn "conv-1" -> conv end)

      :meck.expect(Store.Project.Conversation, :read, fn ^conv ->
        {:ok,
         %{
           metadata: %{
             worktree: %{path: path, branch: "fnord-conv-1", base_branch: "main"}
           }
         }}
      end)

      :meck.expect(UI, :error, fn message ->
        send(self(), {:ui_error, message})
        :ok
      end)

      assert {:error, :not_a_repo} ==
               Cmd.Worktrees.run(%{conversation: "conv-1"}, [:view], [])

      assert_receive {:ui_error, "Worktree path is not inside a git repository"}
    end
  end
end
