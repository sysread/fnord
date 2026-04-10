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

  describe "find_new_ignored_files/2" do
    setup :setup_repo

    test "detects new files in gitignored dirs", %{repo: repo} do
      # Create a worktree-like directory structure
      {:ok, worktree} = tmpdir()
      clone_dir_structure(repo, worktree)

      # Add a file to scratch/ in the worktree that doesn't exist in source
      File.mkdir_p!(Path.join(worktree, "scratch"))
      File.write!(Path.join(worktree, "scratch/plan.md"), "a plan")

      # Set up git in the worktree with the same gitignore
      System.cmd("git", ["init", "--quiet"], cd: worktree)
      File.cp!(Path.join(repo, ".gitignore"), Path.join(worktree, ".gitignore"))

      result = GitCli.Worktree.find_new_ignored_files(repo, worktree)
      assert "scratch/plan.md" in result
    end

    test "ignores files that exist in both source and worktree with same content", %{repo: repo} do
      # Add a file to scratch/ in both
      File.write!(Path.join(repo, "scratch/existing.md"), "same content")

      {:ok, worktree} = tmpdir()
      clone_dir_structure(repo, worktree)
      File.mkdir_p!(Path.join(worktree, "scratch"))
      File.write!(Path.join(worktree, "scratch/existing.md"), "same content")

      System.cmd("git", ["init", "--quiet"], cd: worktree)
      File.cp!(Path.join(repo, ".gitignore"), Path.join(worktree, ".gitignore"))

      result = GitCli.Worktree.find_new_ignored_files(repo, worktree)
      refute "scratch/existing.md" in result
    end

    test "detects files that differ between source and worktree", %{repo: repo} do
      File.write!(Path.join(repo, "scratch/notes.md"), "old content")

      {:ok, worktree} = tmpdir()
      clone_dir_structure(repo, worktree)
      File.mkdir_p!(Path.join(worktree, "scratch"))
      File.write!(Path.join(worktree, "scratch/notes.md"), "new content")

      System.cmd("git", ["init", "--quiet"], cd: worktree)
      File.cp!(Path.join(repo, ".gitignore"), Path.join(worktree, ".gitignore"))

      result = GitCli.Worktree.find_new_ignored_files(repo, worktree)
      assert "scratch/notes.md" in result
    end

    test "excludes files in dirs that only exist in worktree (build artifacts)", %{repo: repo} do
      {:ok, worktree} = tmpdir()
      clone_dir_structure(repo, worktree)

      # Simulate _build/ - exists only in worktree, not in source
      File.mkdir_p!(Path.join(worktree, "_build/dev"))
      File.write!(Path.join(worktree, "_build/dev/some_artifact"), "compiled")

      System.cmd("git", ["init", "--quiet"], cd: worktree)
      # Add _build/ to gitignore
      File.write!(
        Path.join(worktree, ".gitignore"),
        File.read!(Path.join(repo, ".gitignore")) <> "\n_build/"
      )

      result = GitCli.Worktree.find_new_ignored_files(repo, worktree)
      refute Enum.any?(result, &String.starts_with?(&1, "_build/"))
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

  # Copies the directory structure (but not .git/) from source to dest
  defp clone_dir_structure(source, dest) do
    source
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: false)
    |> Enum.reject(&String.contains?(&1, ".git"))
    |> Enum.each(fn path ->
      rel = Path.relative_to(path, source)
      target = Path.join(dest, rel)

      if File.dir?(path) do
        File.mkdir_p!(target)
      else
        File.mkdir_p!(Path.dirname(target))
        File.cp!(path, target)
      end
    end)
  end
end
