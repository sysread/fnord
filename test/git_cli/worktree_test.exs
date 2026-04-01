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
        assert Path.expand(root, project.source_root) == project.source_root
      end)
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
