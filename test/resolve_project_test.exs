defmodule ResolveProjectTest do
  use Fnord.TestCase, async: false

  describe "resolve_from_cwd/1" do
    test "discovers when cwd == project root" do
      project = mock_project("p1")
      assert {:ok, "p1"} = ResolveProject.resolve_from_cwd(project.source_root)
    end

    test "discovers when cwd is a subdirectory of project root" do
      project = mock_project("p1")
      subdir = Path.join(project.source_root, "a/b/c")
      File.mkdir_p!(subdir)
      assert {:ok, "p1"} = ResolveProject.resolve_from_cwd(subdir)
    end

    test "does not discover when cwd is outside any configured root" do
      project = mock_project("p1")
      {:ok, other} = Briefly.create(directory: true)
      refute String.starts_with?(other, project.source_root)
      assert {:error, :not_in_project} = ResolveProject.resolve_from_cwd(other)
    end

    test "chooses deepest project when multiple roots contain cwd" do
      parent = mock_project("parent")
      child_root = Path.join(parent.source_root, "nested")
      File.mkdir_p!(child_root)

      # add child project under settings
      settings = Settings.new()
      Settings.set_project_data(settings, "child", %{"root" => child_root})
      Settings.set_project("child")

      deep = Path.join(child_root, "deeper/sub")
      File.mkdir_p!(deep)
      assert {:ok, "child"} = ResolveProject.resolve_from_cwd(deep)
    end
  end

  describe "resolve_from_worktree/0" do
    test "worktree fallback discovers when cwd is inside git repo" do
      project = mock_git_project("p1")
      sub = Path.join(project.source_root, "lib/foo")
      File.mkdir_p!(sub)

      assert {:ok, "p1"} = ResolveProject.resolve_from_cwd(project.source_root)
      assert {:ok, "p1"} = ResolveProject.resolve_from_cwd(sub)
    end
  end
end
