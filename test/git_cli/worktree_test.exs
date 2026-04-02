defmodule GitCli.WorktreeTest do
  use Fnord.TestCase, async: false

  defp cd(dir, fun) do
    original = File.cwd!()
    File.cd!(dir)

    try do
      fun.()
    after
      File.cd!(original)
    end
  end

  describe "worktree path resolution" do
    test "default worktree root is scoped under the user home" do
      assert GitCli.Worktree.default_root("demo") ==
               Path.join([Settings.get_user_home(), ".fnord", "projects", "demo", "worktrees"])
    end

    test "default conversation worktree path is scoped by conversation id" do
      assert GitCli.Worktree.conversation_path("demo", "conv-1") ==
               Path.join([
                 Settings.get_user_home(),
                 ".fnord",
                 "projects",
                 "demo",
                 "worktrees",
                 "conv-1"
               ])
    end
  end

  describe "worktree lifecycle helpers" do
    setup do
      project = mock_git_project("git-cli-worktree-test")
      {:ok, project: project}
    end

    test "list(nil) returns not_a_repo" do
      assert {:error, :not_a_repo} = GitCli.Worktree.list(nil)
    end

    test "project_root reports repo status inside and outside git", %{project: project} do
      {:ok, tmp} = tmpdir()

      cd(tmp, fn ->
        assert {:error, :not_a_repo} = GitCli.Worktree.project_root()
      end)

      cd(project.source_root, fn ->
        assert {:ok, root} = GitCli.Worktree.project_root()
        assert Path.basename(root) == Path.basename(project.source_root)
      end)
    end

    test "helpers honor project root override from a non-git directory", %{project: project} do
      {:ok, tmp} = tmpdir()

      on_exit(fn ->
        Settings.set_project_root_override(nil)
      end)

      cd(tmp, fn ->
        Settings.set_project_root_override(project.source_root)

        assert GitCli.is_git_repo?()
        assert GitCli.is_worktree?()
        assert GitCli.repo_root() =~ Path.basename(project.source_root)
        assert GitCli.worktree_root() =~ Path.basename(project.source_root)

        info = GitCli.git_info()
        assert info == "Note: this project is not under git version control."
      end)
    end

    test "rollback_created_worktree uses the created path on cleanup", %{project: project} do
      {:ok, tmp} = tmpdir()
      worktree_path = Path.join(tmp, "created-worktree")
      current_pid = self()

      Enum.each([Services.Globals, Services.Conversation, GitCli.Worktree, GitCli], fn module ->
        try do
          :meck.unload(module)
        catch
          _, _ -> :ok
        end

        :meck.new(module, [:non_strict])
      end)

      on_exit(fn ->
        Enum.each([Services.Globals, Services.Conversation, GitCli.Worktree, GitCli], fn module ->
          try do
            :meck.unload(module)
          catch
            _, _ -> :ok
          end
        end)
      end)

      :meck.expect(Services.Globals, :get_env, fn :fnord, :current_conversation, nil ->
        current_pid
      end)

      :meck.expect(Services.Conversation, :get_id, fn ^current_pid -> "conv-1" end)
      :meck.expect(Services.Conversation, :get_conversation_meta, fn ^current_pid -> %{} end)
      :meck.expect(GitCli.Worktree, :normalize_worktree_meta_in_parent, fn meta -> meta end)
      :meck.expect(GitCli.Worktree, :normalize_worktree_meta, fn meta -> meta end)

      :meck.expect(GitCli.Worktree, :create, fn _repo_root, _conversation_id, _meta ->
        {:ok, %{path: worktree_path, branch: "feature", base_branch: "main"}}
      end)

      :meck.expect(Services.Conversation, :upsert_conversation_meta, fn ^current_pid, _meta ->
        {:error, :not_found}
      end)

      :meck.expect(GitCli, :repo_root, fn -> project.source_root end)

      :meck.expect(GitCli.Worktree, :delete, fn root, path ->
        assert root == project.source_root
        assert path == worktree_path
        send(self(), :rollback_delete_called)
        {:ok, :ok}
      end)

      assert {:error, :not_found} =
               AI.Tools.Git.Worktree.call(%{
                 "action" => "create",
                 "project" => project.name,
                 "conversation_id" => "conv-1"
               })

      assert_received :rollback_delete_called
    end

    test "rollback_created_worktree also cleans up when binding exits", %{project: project} do
      {:ok, tmp} = tmpdir()
      worktree_path = Path.join(tmp, "created-worktree-exit")
      current_pid = self()
      reason = :noproc

      Enum.each([Services.Globals, Services.Conversation, GitCli.Worktree, GitCli], fn module ->
        try do
          :meck.unload(module)
        catch
          _, _ -> :ok
        end

        :meck.new(module, [:non_strict])
      end)

      on_exit(fn ->
        Enum.each([Services.Globals, Services.Conversation, GitCli.Worktree, GitCli], fn module ->
          try do
            :meck.unload(module)
          catch
            _, _ -> :ok
          end
        end)
      end)

      :meck.expect(Services.Globals, :get_env, fn :fnord, :current_conversation, nil ->
        current_pid
      end)

      :meck.expect(Services.Conversation, :get_id, fn ^current_pid -> "conv-1" end)
      :meck.expect(Services.Conversation, :get_conversation_meta, fn ^current_pid -> %{} end)
      :meck.expect(GitCli.Worktree, :normalize_worktree_meta_in_parent, fn meta -> meta end)
      :meck.expect(GitCli.Worktree, :normalize_worktree_meta, fn meta -> meta end)

      :meck.expect(GitCli.Worktree, :create, fn _repo_root, _conversation_id, _meta ->
        {:ok, %{path: worktree_path, branch: "feature", base_branch: "main"}}
      end)

      :meck.expect(Services.Conversation, :upsert_conversation_meta, fn ^current_pid, _meta ->
        exit(reason)
      end)

      :meck.expect(GitCli, :repo_root, fn -> project.source_root end)

      :meck.expect(GitCli.Worktree, :delete, fn root, path ->
        assert root == project.source_root
        assert path == worktree_path
        send(self(), :rollback_delete_called)
        {:ok, :ok}
      end)

      assert {:error, {:conversation_bind_failed, {:exit, ^reason}}} =
               AI.Tools.Git.Worktree.call(%{
                 "action" => "create",
                 "project" => project.name,
                 "conversation_id" => "conv-1"
               })

      assert_received :rollback_delete_called
    end

    test "recursive_size returns 0 for missing path and positive size for files" do
      {:ok, tmp} = tmpdir()
      missing = Path.join(tmp, "missing")
      present = Path.join(tmp, "present")
      File.mkdir_p!(present)
      File.write!(Path.join(present, "a.txt"), "abcdef")
      File.write!(Path.join(present, "b.txt"), "ghijkl")

      assert GitCli.Worktree.recursive_size(missing) == 0
      assert GitCli.Worktree.recursive_size(present) > 0
    end

    test "normalize_worktree_meta handles atom and string keyed maps" do
      assert GitCli.Worktree.normalize_worktree_meta(%{
               path: "/tmp/wt",
               branch: "feature",
               base_branch: "main"
             }) == %{
               path: "/tmp/wt",
               branch: "feature",
               base_branch: "main"
             }

      assert GitCli.Worktree.normalize_worktree_meta(%{
               "path" => "/tmp/wt",
               "branch" => "feature",
               "base_branch" => "main"
             }) == %{
               path: "/tmp/wt",
               branch: "feature",
               base_branch: "main"
             }
    end
  end
end
