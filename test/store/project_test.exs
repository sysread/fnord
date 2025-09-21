defmodule Store.ProjectTest do
  use Fnord.TestCase

  setup do: {:ok, project: mock_git_project("blarg")}

  alias Store.Project

  describe "path helpers" do
    test "expand_path/2 returns absolute path", %{project: project} do
      relative = "foo.txt"
      expected = Path.join(project.source_root, relative)
      assert Project.expand_path(relative, project) == expected
    end

    test "relative_path/2 returns path relative to source_root", %{project: project} do
      file = mock_source_file(project, "bar.txt", "hello")
      assert Project.relative_path(file, project) == "bar.txt"
    end
  end

  describe "find_path_in_source_root/2" do
    test "detects directories", %{project: project} do
      assert Project.find_path_in_source_root(project, ".") ==
               {:ok, :dir, project.source_root}
    end

    test "detects files and not found", %{project: project} do
      _created = mock_source_file(project, "baz.txt", "data")
      abs = Path.join(project.source_root, "baz.txt")
      missing = Path.join(project.source_root, "nope.txt")

      assert Project.find_path_in_source_root(project, "baz.txt") ==
               {:ok, :file, abs}

      assert Project.find_path_in_source_root(project, "nope.txt") ==
               {:ok, :enoent, missing}
    end
  end

  describe "find_file/2" do
    test "finds existing file by absolute path", %{project: project} do
      file = mock_source_file(project, "exists.txt", "ok")
      assert {:ok, found} = Project.find_file(project, file)
      assert found == file
    end

    test "returns :enoent for missing absolute path", %{project: project} do
      ghost = Path.join(project.source_root, "ghost.txt")
      assert {:error, :enoent} = Project.find_file(project, ghost)
    end

    test "resolves symlink inside project", %{project: project} do
      target = mock_source_file(project, "real.txt", "content")
      link = Path.join(project.source_root, "link.txt")
      File.ln_s(target, link)

      assert {:ok, found} = Project.find_file(project, "link.txt")
      assert found == target
    end

    test "rejects symlink pointing outside project", %{project: project} do
      {:ok, outside_dir} = tmpdir()
      outside_file = Path.join(outside_dir, "outside.txt")
      File.write!(outside_file, "secret")

      link = Path.join(project.source_root, "outside_link.txt")
      File.ln_s(outside_file, link)

      assert {:error, :enoent} = Project.find_file(project, "outside_link.txt")
    end

    test "rejects symlink loop", %{project: project} do
      link1 = Path.join(project.source_root, "loop1.txt")
      link2 = Path.join(project.source_root, "loop2.txt")

      # Create symlink loop
      File.ln_s(link2, link1)
      File.ln_s(link1, link2)

      assert {:error, :enoent} = Project.find_file(project, "loop1.txt")
      assert {:error, :enoent} = Project.find_file(project, "loop2.txt")
    end

    test "find_file rejects path traversal outside project", %{project: project} do
      outside_path = Path.expand(Path.join(project.source_root, "../outside.txt"))
      # Create the outside file
      File.write!(outside_path, "bad stuff")

      assert {:error, :enoent} = Project.find_file(project, "../outside.txt")
    end

    test "find_file handles complex nested symlinks inside project", %{project: project} do
      real_file = mock_source_file(project, "deep_real.txt", "data")
      link1 = Path.join(project.source_root, "link1.txt")
      link2 = Path.join(project.source_root, "link2.txt")

      File.ln_s(real_file, link1)
      File.ln_s(link1, link2)

      assert {:ok, found} = Project.find_file(project, "link2.txt")
      assert found == real_file
    end
  end

  test "create/1 and exists_in_store?/1", %{project: project} do
    refute Project.exists_in_store?(project)
    Project.create(project)
    assert Project.exists_in_store?(project)
  end

  describe "index_status/1" do
    test "classifies deleted, new, and stale entries", %{project: project} do
      a = mock_source_file(project, "a.txt", "foo")
      entry_a = Store.Project.Entry.new_from_file_path(project, a)
      Store.Project.Entry.save(entry_a, "", "", [])

      c = mock_source_file(project, "c.txt", "baz")
      entry_c = Store.Project.Entry.new_from_file_path(project, c)
      Store.Project.Entry.save(entry_c, "", "", [])

      b = mock_source_file(project, "b.txt", "bar")

      File.rm!(c)
      File.write!(a, "changed")

      status = Store.Project.index_status(project)

      deleted = status.deleted |> Enum.map(& &1.file) |> MapSet.new()
      new = status.new |> Enum.map(& &1.file) |> MapSet.new()
      stale = status.stale |> Enum.map(& &1.file) |> MapSet.new()

      assert deleted == MapSet.new([c])
      assert new == MapSet.new([b])
      assert stale == MapSet.new([a])
    end
  end

  describe "index_status/1 when source_root is nil" do
    test "does not crash and returns empty lists" do
      # Using new/2 to create a project with no source_root
      {:ok, tmp} = tmpdir()
      project = Store.Project.new("no_root", tmp)
      assert project.source_root == nil

      status = Store.Project.index_status(project)
      assert status == %{new: [], stale: [], deleted: []}
    end
  end

  describe "source_files/1 when source_root is nil" do
    test "returns {project, []} without crashing" do
      # Minimal project struct with no source_root field
      project = %Store.Project{
        name: "no_root",
        store_path: "/tmp",
        source_root: nil,
        exclude: ["foo"],
        exclude_cache: nil
      }

      assert Store.Project.source_files(project) == {project, []}
    end
  end

  describe "excluded_paths/1 when source_root is nil" do
    test "user_excluded paths used without invoking git_ignored" do
      # Construct project with exclude list and nil source_root
      project = %Store.Project{
        name: "no_root",
        store_path: "/tmp",
        source_root: nil,
        exclude: ["bar.txt"],
        exclude_cache: nil
      }

      # source_files bypasses excluded_paths and returns empty
      {proj, files} = Store.Project.source_files(project)
      assert proj.exclude_cache == nil
      assert files == []
      # index_status should also not crash and use only exclude list
      status = Store.Project.index_status(project)
      assert status == %{new: [], stale: [], deleted: []}
    end

    test "index_status ignores git and uses only user_excluded" do
      # Create a dummy project struct with nil source_root and a user exclude list
      project = %Store.Project{
        name: "no_root",
        store_path: "/tmp",
        source_root: nil,
        exclude: ["dummy"],
        exclude_cache: nil
      }

      # index_status should not crash and produce empty lists
      status = Store.Project.index_status(project)
      assert status == %{new: [], stale: [], deleted: []}
    end
  end
end
