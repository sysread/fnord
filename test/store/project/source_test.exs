defmodule Store.Project.SourceTest do
  use Fnord.TestCase, async: false

  alias Store.Project.Source

  describe "mode/1" do
    test "returns :fs for nil project" do
      assert Source.mode(nil) == :fs
    end

    test "returns :fs for project with nil source_root" do
      assert Source.mode(%Store.Project{source_root: nil}) == :fs
    end

    test "returns :fs for a non-git source_root" do
      project = mock_project("source_mode_fs")
      assert Source.mode(project) == :fs
    end

    test "returns :fs for an empty git repo (no resolvable default branch)" do
      project = mock_git_project("source_mode_empty_git")
      # mock_git_project inits but doesn't commit, so there's no main ref.
      assert Source.mode(project) == :fs
    end

    test "returns :git for a committed git repo with local main" do
      project = mock_committed_git_project("source_mode_git")
      assert Source.mode(project) == :git
    end
  end

  describe "default_branch/1" do
    test "returns nil for non-git project" do
      project = mock_project("source_default_none")
      assert Source.default_branch(project) == nil
    end

    test "returns the local main branch name for a committed git repo" do
      project = mock_committed_git_project("source_default_main")
      assert Source.default_branch(project) == "main"
    end
  end

  describe "list/1" do
    test "fs mode enumerates the working tree and leaves hash nil" do
      project = mock_project("source_list_fs")
      mock_source_file(project, "a.txt", "alpha")
      mock_source_file(project, "nested/b.txt", "beta")

      entries = Source.list(project)

      assert length(entries) >= 2

      a = Enum.find(entries, &(&1.rel_path == "a.txt"))
      b = Enum.find(entries, &(&1.rel_path == "nested/b.txt"))

      assert a.hash == nil
      assert b.hash == nil
      assert a.abs_path == Path.join(project.source_root, "a.txt")
      assert b.abs_path == Path.join(project.source_root, "nested/b.txt")
    end

    test "git mode enumerates the default branch's tree with blob SHAs as hash" do
      project = mock_committed_git_project("source_list_git", "tracked.txt", "contents")

      # WIP edits in the working tree must not leak into the listing -
      # indexing follows the default branch, not the working tree.
      File.write!(Path.join(project.source_root, "wip.txt"), "not committed")

      entries = Source.list(project)

      tracked = Enum.find(entries, &(&1.rel_path == "tracked.txt"))
      assert tracked
      assert is_binary(tracked.hash)
      assert byte_size(tracked.hash) == 40
      refute Enum.any?(entries, &(&1.rel_path == "wip.txt"))
    end
  end

  describe "read/2" do
    test "nil project returns :no_project error" do
      assert Source.read(nil, "anything") == {:error, :no_project}
    end

    test "fs mode reads from the working tree" do
      project = mock_project("source_read_fs")
      mock_source_file(project, "a.txt", "fs content")

      assert {:ok, "fs content"} = Source.read(project, "a.txt")
    end

    test "git mode reads the default-branch blob, not the working tree" do
      project = mock_committed_git_project("source_read_git", "f.txt", "committed")

      # Modify the working tree. The default-branch blob must still win.
      File.write!(Path.join(project.source_root, "f.txt"), "WIP mutation")

      assert {:ok, "committed"} = Source.read(project, "f.txt")
    end
  end

  describe "hash/2" do
    test "nil project returns :no_project error" do
      assert Source.hash(nil, "anything") == {:error, :no_project}
    end

    test "fs mode returns sha256 of working-tree content" do
      project = mock_project("source_hash_fs")
      mock_source_file(project, "a.txt", "hello")

      expected =
        :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)

      assert {:ok, ^expected} = Source.hash(project, "a.txt")
    end

    test "git mode returns the branch blob SHA, independent of the working tree" do
      project = mock_committed_git_project("source_hash_git", "f.txt", "committed")
      File.write!(Path.join(project.source_root, "f.txt"), "WIP mutation")

      {:ok, blob_sha} = Source.hash(project, "f.txt")
      assert byte_size(blob_sha) == 40
    end

    test "git mode returns :not_in_tree for files only in the working tree" do
      project = mock_committed_git_project("source_hash_wip_only", "tracked.txt", "x")
      File.write!(Path.join(project.source_root, "wip.txt"), "untracked")

      assert {:error, :not_in_tree} = Source.hash(project, "wip.txt")
    end
  end

  describe "exists?/2" do
    test "false for nil project" do
      refute Source.exists?(nil, "a.txt")
    end

    test "fs mode: true for files that exist in the working tree" do
      project = mock_project("source_exists_fs")
      mock_source_file(project, "a.txt", "x")

      assert Source.exists?(project, "a.txt")
      refute Source.exists?(project, "ghost.txt")
    end

    test "git mode: true only for files tracked on the default branch" do
      project = mock_committed_git_project("source_exists_git", "tracked.txt", "x")
      File.write!(Path.join(project.source_root, "wip.txt"), "untracked")

      assert Source.exists?(project, "tracked.txt")
      refute Source.exists?(project, "wip.txt")
    end
  end

  # Helper: create a git project with an initial commit so the default
  # branch resolves. Optional filename/content adds a single tracked file
  # to the initial commit.
  defp mock_committed_git_project(name, filename \\ "placeholder.txt", content \\ "init") do
    project = mock_git_project(name)
    repo = project.source_root

    File.write!(Path.join(repo, filename), content)
    git_config_user!(project)
    System.cmd("git", ["add", "."], cd: repo, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "init", "--quiet"], cd: repo, stderr_to_stdout: true)

    project
  end
end
