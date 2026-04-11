defmodule AI.Tools.File.NotesTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Notes

  describe "read_args/1" do
    test "accepts file" do
      assert {:ok, %{"file" => "/abs/path.ex"}} = Notes.read_args(%{"file" => "/abs/path.ex"})
    end

    test "accepts file_path (back-compat)" do
      assert {:ok, %{"file" => "/abs/path.ex"}} =
               Notes.read_args(%{"file_path" => "/abs/path.ex"})
    end

    test "errors when missing file" do
      assert {:error, :missing_argument, "file"} = Notes.read_args(%{})
    end
  end

  describe "call/1" do
    test "returns missing required parameter message when file not present" do
      assert {:error, "Missing required parameter: file."} = Notes.call(%{})
    end

    test "returns user-friendly message when project is not indexed" do
      # Fnord.TestCase sets up a HOME, but project may not be selected at all.
      # Today, AI.Tools.File.Notes.call/1 should return a friendly error (not crash)
      # when the project is not set / not indexed.
      assert {:error, msg} = Notes.call(%{"file" => "/does/not/matter.ex"})
      assert msg =~ "not yet been indexed"
    end
  end

  describe "call/1 - gitignored source fallback" do
    setup do
      # Set up a real source repo with a gitignored scratch file plus a
      # "worktree" directory that only has tracked files. Mirrors the setup
      # in source_fallback_test.exs.
      project = mock_git_project("notes-source-fallback-test")
      Store.Project.create(project)
      source_root = project.source_root
      git_config_user!(project)
      git_ignore(project, ["scratch/"])

      File.mkdir_p!(Path.join(source_root, "scratch"))
      File.write!(Path.join(source_root, "scratch/plan.md"), "the plan")
      File.write!(Path.join(source_root, "main.ex"), "defmodule Main, do: nil")

      System.cmd("git", ["add", "."], cd: source_root)
      System.cmd("git", ["commit", "-m", "init", "--quiet"], cd: source_root)

      {:ok, worktree} = tmpdir()
      File.cp!(Path.join(source_root, ".gitignore"), Path.join(worktree, ".gitignore"))
      File.cp!(Path.join(source_root, "main.ex"), Path.join(worktree, "main.ex"))
      System.cmd("git", ["init", "--quiet"], cd: worktree)
      System.cmd("git", ["config", "user.name", "Test"], cd: worktree)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: worktree)
      System.cmd("git", ["add", "."], cd: worktree)
      System.cmd("git", ["commit", "-m", "wt", "--quiet"], cd: worktree)

      Settings.set_project_root_override(worktree)
      Services.Globals.put_env(:fnord, :original_project_root, source_root)

      on_exit(fn ->
        Settings.set_project_root_override(nil)
        Services.Globals.delete_env(:fnord, :original_project_root)
      end)

      {:ok, source_root: source_root, worktree: worktree}
    end

    test "returns stub notes pointing at file_contents_tool for gitignored files", %{
      source_root: source_root
    } do
      assert {:ok, out} = Notes.call(%{"file" => "scratch/plan.md"})
      assert out =~ Path.join(source_root, "scratch/plan.md")
      assert out =~ "gitignored"
      assert out =~ "file_contents_tool"
      assert out =~ "source-fallback"
    end

    test "returns friendly enoent hint for truly missing files" do
      assert {:error, msg} = Notes.call(%{"file" => "does/not/exist.md"})
      assert msg =~ "not found"
      assert msg =~ "file_contents_tool"
    end

    test "still reads tracked files from the worktree normally" do
      assert {:ok, out} = Notes.call(%{"file" => "main.ex"})
      assert out =~ "main.ex"
      # No gitignored banner for tracked files
      refute out =~ "gitignored"
    end
  end
end
