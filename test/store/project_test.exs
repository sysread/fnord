defmodule ProjectTest do
  use Fnord.TestCase

  setup do: set_config(workers: 1, quiet: true)
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
               {:ok, :not_found, missing}
    end
  end

  describe "find_file/2" do
    test "finds existing file by absolute path", %{project: project} do
      file = mock_source_file(project, "exists.txt", "ok")
      assert {:ok, found} = Project.find_file(project, file)
      assert found == file
    end

    test "returns :not_found for missing absolute path", %{project: project} do
      ghost = Path.join(project.source_root, "ghost.txt")
      assert {:error, :not_found} = Project.find_file(project, ghost)
    end
  end

  test "create/1 and exists_in_store?/1", %{project: project} do
    refute Project.exists_in_store?(project)
    Project.create(project)
    assert Project.exists_in_store?(project)
  end
end
