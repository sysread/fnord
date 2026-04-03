defmodule AI.Tools.File.EditWorktreeTest do
  @moduledoc """
  Verifies that file edits resolve against the project root override (worktree)
  rather than the original source root. Exercises the full edit pipeline:
  path resolution, file read, change application, and commit_changes write.
  """
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Edit

  setup do
    # Create the "real" project root
    project = mock_project("edit-wt-test")

    # Create a second temp dir to act as the worktree
    {:ok, worktree_dir} = tmpdir()

    # Set the override BEFORE getting the project again, so source_root
    # reflects the worktree
    Settings.set_project_root_override(worktree_dir)

    on_exit(fn ->
      Settings.set_project_root_override(nil)
    end)

    {:ok, project: project, worktree_dir: worktree_dir}
  end

  setup do
    :meck.new(AI.Agent.Code.Patcher, [:no_link, :non_strict, :passthrough])
    on_exit(fn -> :meck.unload(AI.Agent.Code.Patcher) end)
    :ok
  end

  setup do
    Settings.set_edit_mode(true)
    Settings.set_auto_approve(true)

    on_exit(fn ->
      Settings.set_edit_mode(false)
      Settings.set_auto_approve(false)
    end)
  end

  test "exact edit writes to worktree, not original source root", %{
    project: project,
    worktree_dir: worktree_dir
  } do
    original_content = "hello world\n"
    edited_content = "hello worktree\n"

    # Create the file in the worktree dir (not the original project root)
    worktree_file = Path.join(worktree_dir, "target.txt")
    File.write!(worktree_file, original_content)

    # Also create the same file in the original root with DIFFERENT content
    # so we can detect if the edit accidentally targets the wrong location
    original_root_file = Path.join(project.source_root, "target.txt")
    File.write!(original_root_file, "this is the ORIGINAL root, not the worktree\n")

    assert {:ok, result} =
             Edit.call(%{
               "file" => "target.txt",
               "changes" => [
                 %{"old_string" => "hello world", "new_string" => "hello worktree"}
               ]
             })

    assert result.diff =~ "-hello world"
    assert result.diff =~ "+hello worktree"

    # The worktree file should have been modified
    assert File.read!(worktree_file) == edited_content

    # The original root file should be untouched
    assert File.read!(original_root_file) == "this is the ORIGINAL root, not the worktree\n"
  end

  test "natural language edit writes to worktree via patcher", %{
    project: project,
    worktree_dir: worktree_dir
  } do
    original_content = "defmodule Foo do\n  def bar, do: :ok\nend\n"
    edited_content = "defmodule Foo do\n  def bar, do: :changed\nend\n"

    worktree_file = Path.join(worktree_dir, "lib/foo.ex")
    File.mkdir_p!(Path.dirname(worktree_file))
    File.write!(worktree_file, original_content)

    # Different content in original root
    original_root_file = Path.join(project.source_root, "lib/foo.ex")
    File.mkdir_p!(Path.dirname(original_root_file))
    File.write!(original_root_file, "ORIGINAL ROOT CONTENT\n")

    :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
      # The patcher should receive the worktree absolute path
      assert String.starts_with?(args[:file], worktree_dir)
      {:ok, edited_content}
    end)

    assert {:ok, result} =
             Edit.call(%{
               "file" => "lib/foo.ex",
               "changes" => [
                 %{"instructions" => "Change bar to return :changed"}
               ]
             })

    assert result.diff =~ "-  def bar, do: :ok"
    assert result.diff =~ "+  def bar, do: :changed"

    # Worktree file modified
    assert File.read!(worktree_file) == edited_content

    # Original root untouched
    assert File.read!(original_root_file) == "ORIGINAL ROOT CONTENT\n"
  end

  test "file read resolves against worktree override", %{worktree_dir: worktree_dir} do
    content = "worktree content\n"
    worktree_file = Path.join(worktree_dir, "read_test.txt")
    File.write!(worktree_file, content)

    # get_project() requires the project to exist in the store; use it
    # directly since the override is already set
    {:ok, project} = Store.get_project()
    assert {:ok, resolved} = Util.find_file_within_root("read_test.txt", project.source_root)
    assert resolved == worktree_file
    assert File.read!(resolved) == content
  end

  test "file that exists only in worktree is found", %{
    project: project,
    worktree_dir: worktree_dir
  } do
    # File exists ONLY in the worktree, not in the original root
    worktree_only = Path.join(worktree_dir, "worktree_only.txt")
    File.write!(worktree_only, "only here\n")

    refute File.exists?(Path.join(project.source_root, "worktree_only.txt"))

    # Resolve via the overridden project
    {:ok, wt_project} = Store.get_project()

    assert {:ok, resolved} =
             Util.find_file_within_root("worktree_only.txt", wt_project.source_root)

    assert resolved == worktree_only
  end
end
