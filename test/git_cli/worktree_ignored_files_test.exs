defmodule GitCli.Worktree.IgnoredFilesTest do
  use Fnord.TestCase, async: false

  defp setup_repo(_context) do
    project = mock_git_project("ignored-files-test")
    repo = project.source_root
    git_config_user!(project)

    # Create a scratch/ directory and gitignore it
    File.mkdir_p!(Path.join(repo, "scratch"))
    git_ignore(project, ["scratch/"])

    # Create an initial commit so git is fully initialized
    System.cmd("git", ["add", ".gitignore"], cd: repo)
    System.cmd("git", ["commit", "-m", "initial", "--quiet"], cd: repo)

    {:ok, project: project, repo: repo}
  end

  describe "path_ignored?/2" do
    setup :setup_repo

    test "returns true for gitignored paths", %{repo: repo} do
      file = Path.join(repo, "scratch/plan.md")
      File.write!(file, "some plan")
      assert GitCli.Worktree.path_ignored?(repo, file)
    end

    test "returns false for tracked paths", %{repo: repo} do
      file = Path.join(repo, "lib/main.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule Main, do: nil")
      refute GitCli.Worktree.path_ignored?(repo, file)
    end

    test "returns false for nonexistent paths in tracked dirs", %{repo: repo} do
      refute GitCli.Worktree.path_ignored?(repo, Path.join(repo, "lib/nope.ex"))
    end

    test "returns true for paths matching gitignore patterns even if file doesn't exist", %{
      repo: repo
    } do
      assert GitCli.Worktree.path_ignored?(repo, Path.join(repo, "scratch/nonexistent.md"))
    end
  end

  describe "copy_ignored_files/3" do
    setup :setup_repo

    test "copies files from worktree to source", %{repo: repo} do
      {:ok, worktree} = tmpdir()
      File.mkdir_p!(Path.join(worktree, "scratch"))
      File.write!(Path.join(worktree, "scratch/plan.md"), "the plan")

      results = GitCli.Worktree.copy_ignored_files(repo, worktree, ["scratch/plan.md"])

      assert [{:ok, "scratch/plan.md"}] = results
      assert File.read!(Path.join(repo, "scratch/plan.md")) == "the plan"
    end

    test "creates parent directories as needed", %{repo: repo} do
      {:ok, worktree} = tmpdir()
      File.mkdir_p!(Path.join(worktree, "scratch/deep/nested"))
      File.write!(Path.join(worktree, "scratch/deep/nested/file.md"), "content")

      results =
        GitCli.Worktree.copy_ignored_files(repo, worktree, ["scratch/deep/nested/file.md"])

      assert [{:ok, "scratch/deep/nested/file.md"}] = results
      assert File.read!(Path.join(repo, "scratch/deep/nested/file.md")) == "content"
    end

    test "returns error tuples for missing source files", %{repo: repo} do
      {:ok, worktree} = tmpdir()

      results = GitCli.Worktree.copy_ignored_files(repo, worktree, ["scratch/missing.md"])

      assert [{:error, "scratch/missing.md", _reason}] = results
    end
  end
end
