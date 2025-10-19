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

    test "sibling with prefix should not match" do
      mock_project("p1")
      p10 = mock_project("p10")
      cwd = p10.source_root
      assert {:ok, "p10"} = ResolveProject.resolve_from_cwd(cwd)
    end

    test "nested directories still match" do
      project = mock_project("p1")
      nested = Path.join(project.source_root, "foo/bar/baz")
      File.mkdir_p!(nested)
      assert {:ok, "p1"} = ResolveProject.resolve_from_cwd(nested)
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
      assert {:ok, "super"} = ResolveProject.resolve_from_cwd(thog_deployments)
    end
  end

  describe "resolve_from_worktree/0" do
    test "worktree fallback discovers when cwd is inside git repo" do
      project = mock_git_project("p1")
      sub = Path.join(project.source_root, "lib/foo")
      File.mkdir_p!(sub)

      # ensure project is configured for auto-resolution
      settings = Settings.new()
      Settings.set_project_data(settings, "p1", %{"root" => project.source_root})

      :meck.new(GitCli, [:non_strict])
      :meck.expect(GitCli, :worktree_root, fn -> project.source_root end)
      :meck.expect(GitCli, :repo_root, fn -> project.source_root end)

      File.cd!(project.source_root, fn ->
        assert {:ok, "p1"} = ResolveProject.resolve_from_worktree()
      end)

      File.cd!(sub, fn ->
        assert {:ok, "p1"} = ResolveProject.resolve_from_worktree()
      end)

      :meck.unload(GitCli)
    end

    test "prefers exact worktree over exact repo" do
      repo = mock_git_project("repo")
      worktree = mock_git_project("worktree")

      # configure both projects exactly at the candidate roots
      settings = Settings.new()
      Settings.set_project_data(settings, "repo", %{"root" => repo.source_root})
      Settings.set_project_data(settings, "worktree", %{"root" => worktree.source_root})

      :meck.new(GitCli, [:non_strict])
      :meck.expect(GitCli, :worktree_root, fn -> worktree.source_root end)
      :meck.expect(GitCli, :repo_root, fn -> repo.source_root end)

      File.cd!(worktree.source_root, fn ->
        assert {:ok, "worktree"} = ResolveProject.resolve_from_worktree()
      end)

      :meck.unload(GitCli)
    end

    test "picks deepest nested under repo when no exact worktree" do
      {:ok, repo} = Briefly.create(directory: true)
      a_root = Path.join(repo, "a")
      nested = Path.join(repo, "a/b")
      File.mkdir_p!(a_root)
      File.mkdir_p!(nested)

      # configure child projects under repo candidates (no project at repo root)
      settings = Settings.new()
      Settings.set_project_data(settings, "a", %{"root" => a_root})
      Settings.set_project_data(settings, "ab", %{"root" => nested})

      :meck.new(GitCli, [:non_strict])
      :meck.expect(GitCli, :worktree_root, fn -> nil end)
      :meck.expect(GitCli, :repo_root, fn -> repo end)

      File.cd!(nested, fn ->
        assert {:ok, "ab"} = ResolveProject.resolve_from_worktree()
      end)

      :meck.unload(GitCli)
    end

    test "picks nested under worktree when no exact match" do
      project = mock_git_project("p1")
      nested = Path.join(project.source_root, "nested")
      File.mkdir_p!(nested)

      # configure a child project under worktree candidate
      settings = Settings.new()
      Settings.set_project_data(settings, "nested", %{"root" => nested})

      :meck.new(GitCli, [:non_strict])
      :meck.expect(GitCli, :worktree_root, fn -> nested end)
      :meck.expect(GitCli, :repo_root, fn -> project.source_root end)

      File.cd!(nested, fn ->
        assert {:ok, "nested"} = ResolveProject.resolve_from_worktree()
      end)

      :meck.unload(GitCli)
    end

    test "returns error when no matches" do
      _project = mock_git_project("p1")
      {:ok, other} = Briefly.create(directory: true)
      :meck.new(GitCli, [:non_strict])
      :meck.expect(GitCli, :worktree_root, fn -> other end)
      :meck.expect(GitCli, :repo_root, fn -> other end)

      File.cd!(other, fn ->
        assert {:error, :not_in_project} = ResolveProject.resolve_from_worktree()
      end)

      :meck.unload(GitCli)
    end
  end
end
