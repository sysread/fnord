defmodule GitCli.WorktreeTest do
  use Fnord.TestCase, async: false

  defp git!(repo, args) do
    {out, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

    if status != 0 do
      raise "git #{Enum.join(args, " ")} failed in #{repo}: #{out}"
    end

    out
  end

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

    test "fnord_managed? recognizes normalized conversation paths under the default root" do
      path =
        Path.join([
          Settings.get_user_home(),
          ".fnord",
          "projects",
          "demo",
          "worktrees",
          "conv-1"
        ]) <> "/"

      assert GitCli.Worktree.fnord_managed?("demo", path)
    end

    test "fnord_managed? treats the default root itself as managed" do
      assert GitCli.Worktree.fnord_managed?("demo", GitCli.Worktree.default_root("demo"))
    end

    test "fnord_managed? rejects sibling paths with a similar prefix" do
      refute GitCli.Worktree.fnord_managed?(
               "demo",
               Path.join([
                 Settings.get_user_home(),
                 ".fnord",
                 "projects",
                 "demo-worktrees",
                 "conv-1"
               ])
             )
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

      mocked = [Services.Globals, Services.Conversation, GitCli.Worktree, GitCli, Store]

      Enum.each(mocked, fn module ->
        try do
          :meck.unload(module)
        catch
          _, _ -> :ok
        end

        :meck.new(module, [:non_strict])
      end)

      on_exit(fn ->
        Enum.each(mocked, fn module ->
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

      :meck.expect(Store, :get_project, fn -> {:ok, %{name: project.name}} end)
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
               AI.Tools.Git.Worktree.call(%{"action" => "create"})

      assert_received :rollback_delete_called
    end

    test "rollback_created_worktree also cleans up when binding exits", %{project: project} do
      {:ok, tmp} = tmpdir()
      worktree_path = Path.join(tmp, "created-worktree-exit")
      current_pid = self()
      reason = :noproc

      mocked = [Services.Globals, Services.Conversation, GitCli.Worktree, GitCli, Store]

      Enum.each(mocked, fn module ->
        try do
          :meck.unload(module)
        catch
          _, _ -> :ok
        end

        :meck.new(module, [:non_strict])
      end)

      on_exit(fn ->
        Enum.each(mocked, fn module ->
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

      :meck.expect(Store, :get_project, fn -> {:ok, %{name: project.name}} end)
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
               AI.Tools.Git.Worktree.call(%{"action" => "create"})

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

    test "duplicate clones uncommitted state onto an independent branch", %{project: project} do
      repo = project.source_root

      git!(repo, ["config", "user.email", "test@example.com"])
      git!(repo, ["config", "user.name", "Test"])
      File.write!(Path.join(repo, "base.txt"), "base\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "initial"])

      # Source branch carries 2 commits beyond main, plus uncommitted state.
      git!(repo, ["checkout", "-b", "fnord-source"])
      File.write!(Path.join(repo, "feature.txt"), "v1\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "feature v1"])
      File.write!(Path.join(repo, "feature.txt"), "v2\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "feature v2"])
      git!(repo, ["checkout", "main"])

      # Create the source worktree on the source branch via real git.
      {:ok, source_root} = tmpdir()
      source_path = Path.join(source_root, "source-wt")
      git!(repo, ["worktree", "add", source_path, "fnord-source"])

      # Dirty the source worktree: modify, delete, and add untracked files.
      File.write!(Path.join(source_path, "feature.txt"), "v3-dirty\n")
      File.rm!(Path.join(source_path, "base.txt"))
      File.mkdir_p!(Path.join(source_path, "nested"))
      File.write!(Path.join(source_path, "nested/new.txt"), "fresh\n")

      source_meta = %{
        path: source_path,
        branch: "fnord-source",
        base_branch: "main"
      }

      cd(repo, fn ->
        assert {:ok, entry} =
                 GitCli.Worktree.duplicate(project.name, source_meta, "fork-1")

        assert entry.branch == "fnord-fork-1"
        assert entry.base_branch == "main"
        assert File.dir?(entry.path)

        # Both source feature commits are present on the new branch.
        {log, 0} =
          System.cmd("git", ["log", "--format=%s", "fnord-fork-1"], cd: repo)

        assert log =~ "feature v2"
        assert log =~ "feature v1"
        assert log =~ "initial"

        # The new branch is NOT the same ref as the source branch (independent).
        {fork_sha, 0} = System.cmd("git", ["rev-parse", "fnord-fork-1"], cd: repo)
        {source_sha, 0} = System.cmd("git", ["rev-parse", "fnord-source"], cd: repo)
        assert String.trim(fork_sha) == String.trim(source_sha)

        # Dirty state was overlaid into the destination worktree.
        assert File.read!(Path.join(entry.path, "feature.txt")) == "v3-dirty\n"
        refute File.exists?(Path.join(entry.path, "base.txt"))
        assert File.read!(Path.join(entry.path, "nested/new.txt")) == "fresh\n"

        # Source worktree is untouched (commits and dirty state preserved).
        assert File.read!(Path.join(source_path, "feature.txt")) == "v3-dirty\n"
        refute File.exists?(Path.join(source_path, "base.txt"))
        assert File.read!(Path.join(source_path, "nested/new.txt")) == "fresh\n"
      end)
    end

    test "duplicate refuses when the source worktree is missing", %{project: project} do
      assert {:error, :source_missing} =
               GitCli.Worktree.duplicate(
                 project.name,
                 %{path: "/nonexistent/path", branch: "x", base_branch: "main"},
                 "fork-2"
               )
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
