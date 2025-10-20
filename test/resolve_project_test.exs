defmodule ResolveProjectTest do
  use Fnord.TestCase, async: false

  describe "resolve/1" do
    test "discovers when cwd == project root" do
      project = mock_project("p1")
      assert {:ok, "p1"} = ResolveProject.resolve(project.source_root)
    end

    test "discovers when cwd is a subdirectory of project root" do
      project = mock_project("p1")
      subdir = Path.join(project.source_root, "a/b/c")
      File.mkdir_p!(subdir)
      assert {:ok, "p1"} = ResolveProject.resolve(subdir)
    end

    test "does not discover when cwd is outside any configured root" do
      project = mock_project("p1")
      {:ok, other} = Briefly.create(directory: true)
      refute String.starts_with?(other, project.source_root)
      assert {:error, :not_in_project} = ResolveProject.resolve(other)
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
      assert {:ok, "child"} = ResolveProject.resolve(deep)
    end

    test "sibling with prefix should not match" do
      mock_project("p1")
      p10 = mock_project("p10")
      cwd = p10.source_root
      assert {:ok, "p10"} = ResolveProject.resolve(cwd)
    end

    test "nested directories still match" do
      project = mock_project("p1")
      nested = Path.join(project.source_root, "foo/bar/baz")
      File.mkdir_p!(nested)
      assert {:ok, "p1"} = ResolveProject.resolve(nested)
    end

    test "prefers super-project in parent when sibling exists" do
      {:ok, parent_dir} = Briefly.create(directory: true)
      settings = Settings.new()
      Settings.set_project_data(settings, "super", %{"root" => parent_dir})
      Settings.set_project("super")
      thog = Path.join(parent_dir, "thog")
      File.mkdir_p!(thog)
      thog_deployments = Path.join(parent_dir, "thog-deployments")
      File.mkdir_p!(thog_deployments)
      assert {:ok, "super"} = ResolveProject.resolve(thog_deployments)
    end
  end
end
