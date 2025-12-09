defmodule Memory.ProjectTest do
  use Fnord.TestCase, async: false

  describe "init/0" do
    setup do
      project = mock_project("memory_project_init")
      File.mkdir_p!(project.store_path)
      {:ok, project: project}
    end

    test "creates the project memory directory and drops old storage if present", %{
      project: project
    } do
      old_path = Path.join(project.store_path, "memories")
      new_path = Path.join(project.store_path, "memory")

      File.mkdir_p!(old_path)
      assert File.exists?(old_path)

      assert :ok = Memory.Project.init()

      refute File.exists?(old_path)
      assert File.exists?(new_path)
    end
  end

  describe "list/0, save/1, read/1, forget/1" do
    setup do
      project = mock_project("memory_project_roundtrip")
      File.mkdir_p!(project.store_path)
      mem_path = Path.join(project.store_path, "memory")
      File.rm_rf!(mem_path)
      File.mkdir_p!(mem_path)
      {:ok, project: project}
    end

    test "save/1 writes a memory that can be listed and read back", %{project: _project} do
      mem = %Memory{
        scope: :project,
        title: "Project Test",
        slug: Memory.title_to_slug("Project Test"),
        content: "proj content",
        topics: ["topic"],
        embeddings: [0.1]
      }

      assert :ok = Memory.Project.save(mem)
      assert {:ok, titles} = Memory.Project.list()
      assert "Project Test" in titles

      assert {:ok, loaded} = Memory.Project.read("Project Test")
      assert loaded.title == mem.title
      assert loaded.content == mem.content
    end

    test "forget/1 removes a stored memory", %{project: _project} do
      mem = %Memory{
        scope: :project,
        title: "To Forget",
        slug: Memory.title_to_slug("To Forget"),
        content: "content",
        topics: [],
        embeddings: [0.0]
      }

      assert :ok = Memory.Project.save(mem)
      assert {:ok, titles} = Memory.Project.list()
      assert "To Forget" in titles

      assert :ok = Memory.Project.forget("To Forget")
      assert {:ok, titles_after} = Memory.Project.list()
      refute "To Forget" in titles_after
    end
  end
end
