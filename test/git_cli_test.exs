defmodule GitCli.Test do
  use Fnord.TestCase, async: false

  # Helper to change working directory for a block and restore afterward
  defp cd(dir, fun) do
    original = File.cwd!()
    File.cd!(dir)

    try do
      fun.()
    after
      File.cd!(original)
    end
  end

  @moduledoc """
  Unit tests for GitCli: cover repository detection, roots, info strings,
  and ignored-files mapping.
  """

  describe "is_git_repo?/0" do
    setup do
      project = mock_git_project("test-repo")
      {:ok, project: project}
    end

    test "returns false in a non-git directory" do
      {:ok, tmp} = tmpdir()
      cd(tmp, fn -> refute GitCli.is_git_repo?() end)
    end

    test "returns true after `git init`", %{project: project} do
      cd(project.source_root, fn ->
        assert GitCli.is_git_repo?()
      end)
    end
  end

  describe "repo_root/0" do
    setup do
      project = mock_git_project("test-repo")
      {:ok, project: project}
    end

    test "yields the repo root (normalized to absolute) in a git repo", %{project: project} do
      cd(project.source_root, fn ->
        root = GitCli.repo_root()
        assert is_binary(root)
        assert Path.expand(root, project.source_root) == project.source_root
      end)
    end

    test "returns nil in a directory with no git" do
      {:ok, tmp} = tmpdir()
      cd(tmp, fn -> assert GitCli.repo_root() == nil end)
    end
  end

  describe "is_worktree?/0 and worktree_root/0" do
    setup do
      project = mock_git_project("test-repo")
      {:ok, project: project}
    end

    test "outside of git: both are falsey/nil" do
      {:ok, tmp} = tmpdir()

      cd(tmp, fn ->
        refute GitCli.is_worktree?()
        assert GitCli.worktree_root() == nil
      end)
    end

    test "inside a fresh git repo: true and correct root", %{project: project} do
      cd(project.source_root, fn ->
        assert GitCli.is_worktree?()
        wt = GitCli.worktree_root()
        # Ensure worktree_root returns a directory path that matches the repo name
        assert Path.basename(wt) == Path.basename(project.source_root)
      end)
    end
  end

  describe "git_info/0" do
    setup do
      project = mock_git_project("test-repo")
      {:ok, project: project}
    end

    test "in non-git dir returns not-under-git message" do
      {:ok, tmp} = tmpdir()

      cd(tmp, fn ->
        assert GitCli.git_info() ==
                 "Note: this project is not under git version control."
      end)
    end

    test "in git repo returns the multi-line info with root", %{project: project} do
      cd(project.source_root, fn ->
        # Ensure HEAD exists by making an initial empty commit
        System.cmd("git", ["config", "user.email", "test@example.com"])
        System.cmd("git", ["config", "user.name", "Test User"])
        System.cmd("git", ["commit", "--allow-empty", "-m", "initial"])

        # Capture the actual git root from the module under test
        root = GitCli.worktree_root()

        info = GitCli.git_info()
        # The info string should mention git repository status
        assert info =~ "You are working in a git repository."
        assert info =~ "The git root is `#{root}`."
      end)
    end
  end

  describe "ignored_files/1" do
    setup do
      project = mock_git_project("test-repo")
      {:ok, project: project}
    end

    test "lists only files matching .gitignore patterns, as absolute paths", %{project: project} do
      git_ignore(project, ["*.tmp", "logs/"])

      mock_source_file(project, "foo.tmp", "temp")
      File.mkdir_p!(Path.join(project.source_root, "logs"))
      mock_source_file(project, "logs/bar.txt", "log")
      mock_source_file(project, "baz.txt", "normal")

      ignored = GitCli.ignored_files(project.source_root)
      abs_foo = Path.absname("foo.tmp", project.source_root)
      abs_bar = Path.absname("logs/bar.txt", project.source_root)
      abs_baz = Path.absname("baz.txt", project.source_root)
      assert Map.has_key?(ignored, abs_foo)
      assert Map.has_key?(ignored, abs_bar)
      refute Map.has_key?(ignored, abs_baz)
      assert ignored[abs_foo] == true
      assert ignored[abs_bar] == true
    end

    test "returns empty map on git error" do
      {:ok, tmp} = tmpdir()
      assert GitCli.ignored_files(tmp) == %{}
    end

    test "returns empty map for nil root" do
      assert GitCli.ignored_files(nil) == %{}
    end
  end
end
