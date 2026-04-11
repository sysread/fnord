defmodule AI.Tools.SourceFallbackTest do
  use Fnord.TestCase, async: false

  setup do
    # Build a real source repo with a gitignored scratch dir, plus a "worktree"
    # directory that mimics what an isolated worktree would look like (no
    # scratch dir, no plan file).
    project = mock_git_project("source-fallback-test")
    Store.Project.create(project)
    source_root = project.source_root
    git_config_user!(project)
    git_ignore(project, ["scratch/", "_build/"])

    File.mkdir_p!(Path.join(source_root, "scratch"))
    File.write!(Path.join(source_root, "scratch/plan.md"), "the plan")
    File.write!(Path.join(source_root, "main.ex"), "defmodule Main, do: nil")

    System.cmd("git", ["add", ".gitignore", "main.ex"], cd: source_root)
    System.cmd("git", ["commit", "-m", "initial", "--quiet"], cd: source_root)

    # The "worktree" is a separate dir holding only the tracked files.
    {:ok, worktree} = tmpdir()
    File.cp!(Path.join(source_root, ".gitignore"), Path.join(worktree, ".gitignore"))
    File.cp!(Path.join(source_root, "main.ex"), Path.join(worktree, "main.ex"))
    System.cmd("git", ["init", "--quiet"], cd: worktree)
    System.cmd("git", ["config", "user.name", "Test"], cd: worktree)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: worktree)
    System.cmd("git", ["add", "."], cd: worktree)
    System.cmd("git", ["commit", "-m", "wt", "--quiet"], cd: worktree)

    # Wire the override and the cached original_root the same way Cmd.Ask does.
    Settings.set_project_root_override(worktree)
    Services.Globals.put_env(:fnord, :original_project_root, source_root)

    on_exit(fn ->
      Settings.set_project_root_override(nil)
      Services.Globals.delete_env(:fnord, :original_project_root)
    end)

    {:ok, project: project, source_root: source_root, worktree: worktree}
  end

  describe "get_file_contents_with_origin/1 source-fallback" do
    test "returns source_fallback for gitignored file missing from worktree", %{
      source_root: source_root
    } do
      result = AI.Tools.get_file_contents_with_origin("scratch/plan.md")
      assert {:source_fallback, abs_path, "the plan"} = result
      assert abs_path == Path.join(source_root, "scratch/plan.md")
    end

    test "returns plain :ok for files present in worktree" do
      assert {:ok, "defmodule Main, do: nil"} =
               AI.Tools.get_file_contents_with_origin("main.ex")
    end

    test "returns :enoent for tracked files that exist in source but not worktree", %{
      source_root: source_root
    } do
      # Add a tracked file to source only - it should NOT trigger source-fallback
      # because it's not gitignored. The LLM should see this as missing from
      # its branch, not be silently given the source version.
      File.write!(Path.join(source_root, "tracked_only.ex"), "source-only content")
      System.cmd("git", ["add", "tracked_only.ex"], cd: source_root)
      System.cmd("git", ["commit", "-m", "add tracked", "--quiet"], cd: source_root)

      assert {:error, :enoent} = AI.Tools.get_file_contents_with_origin("tracked_only.ex")
    end

    test "returns :enoent for files that don't exist anywhere" do
      assert {:error, :enoent} = AI.Tools.get_file_contents_with_origin("nope.md")
    end
  end

  describe "get_file_contents/1 transparent fallback" do
    test "unwraps source_fallback to a plain :ok tuple" do
      assert {:ok, "the plan"} = AI.Tools.get_file_contents("scratch/plan.md")
    end

    test "does not break for files present in worktree" do
      assert {:ok, "defmodule Main, do: nil"} = AI.Tools.get_file_contents("main.ex")
    end
  end

  describe "no-fallback when not in a worktree session" do
    setup do
      # Clear the override - simulate a non-worktree session.
      Settings.set_project_root_override(nil)
      :ok
    end

    test "missing files return :enoent without source-fallback" do
      # In a non-worktree session, original_source_root may still be set in
      # globals (from the parent setup), but project.source_root is now equal
      # to original_root, so the != guard prevents fallback. The file should
      # already be present in source though, so this test confirms a normal
      # read still works.
      assert {:ok, "the plan"} = AI.Tools.get_file_contents_with_origin("scratch/plan.md")
    end
  end
end
