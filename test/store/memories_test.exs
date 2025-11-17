defmodule Store.MemoriesTest do
  use Fnord.TestCase, async: false

  setup do
    # Clean up memories directory before each test (uses test HOME)
    base = Path.join(Settings.get_user_home(), ".fnord/memories")
    File.rm_rf(base)

    # Clean up any project memories too
    projects_base = Path.join(Settings.get_user_home(), ".fnord/projects")

    if File.dir?(projects_base) do
      projects_base
      |> Path.join("*/memories")
      |> Path.wildcard()
      |> Enum.each(&File.rm_rf/1)
    end

    # Reload Services.Memories to pick up clean state
    Services.Memories.reload()

    {:ok, project: mock_project("test-memories")}
  end

  describe "initialization" do
    test "init/0 creates directory structure" do
      Store.Memories.init()

      base = Path.join(Settings.get_user_home(), ".fnord/memories")
      assert File.dir?(base)
      assert File.exists?(Path.join(base, ".metadata.json"))
    end

    test "initialized?/0 returns true after init" do
      refute Store.Memories.initialized?()
      Store.Memories.init()
      assert Store.Memories.initialized?()
    end
  end

  describe "create/1 and exists?/2" do
    test "creates global memory with all required files" do
      Store.Memories.init()

      memory =
        AI.Memory.new(%{
          label: "test memory",
          response_template: "Test response",
          scope: :global
        })

      assert :ok = Store.Memories.create(memory)
      assert Store.Memories.exists?(memory.slug, :global)

      base = Path.join([Settings.get_user_home(), ".fnord/memories", memory.slug])
      assert File.exists?(Path.join(base, "meta.json"))
      assert File.exists?(Path.join(base, "heuristic.json"))
      assert File.exists?(Path.join(base, "children.log"))
    end

    test "creates project memory when project selected", ctx do
      Store.Memories.init()
      Settings.set_project(ctx.project.name)

      memory =
        AI.Memory.new(%{
          label: "project memory",
          response_template: "Project response",
          scope: :project
        })

      assert :ok = Store.Memories.create(memory)
      assert Store.Memories.exists?(memory.slug, :project)

      base =
        Path.join([
          Settings.get_user_home(),
          ".fnord/projects",
          ctx.project.name,
          "memories",
          memory.slug
        ])

      assert File.dir?(base)
    end
  end

  describe "load_global/0 and load_project/1" do
    test "load_global loads only global memories" do
      Store.Memories.init()

      mem1 =
        AI.Memory.new(%{label: "global one", response_template: "Response 1", scope: :global})

      mem2 =
        AI.Memory.new(%{label: "global two", response_template: "Response 2", scope: :global})

      Store.Memories.create(mem1)
      Store.Memories.create(mem2)

      loaded = Store.Memories.load_global()

      assert length(loaded) == 2
      assert Enum.any?(loaded, &(&1.slug == mem1.slug))
      assert Enum.any?(loaded, &(&1.slug == mem2.slug))
    end

    test "load_project loads project memories", ctx do
      Store.Memories.init()
      Settings.set_project(ctx.project.name)

      mem = AI.Memory.new(%{label: "project mem", response_template: "Response", scope: :project})
      Store.Memories.create(mem)

      loaded = Store.Memories.load_project(ctx.project.name)

      assert length(loaded) == 1
      assert hd(loaded).slug == mem.slug
    end

    test "load_all combines global and project", ctx do
      Store.Memories.init()
      Settings.set_project(ctx.project.name)

      global_mem = AI.Memory.new(%{label: "global", response_template: "Global", scope: :global})

      project_mem =
        AI.Memory.new(%{label: "project", response_template: "Project", scope: :project})

      Store.Memories.create(global_mem)
      Store.Memories.create(project_mem)

      loaded = Store.Memories.load_all(ctx.project.name)

      assert length(loaded) == 2
      assert Enum.any?(loaded, &(&1.scope == :global))
      assert Enum.any?(loaded, &(&1.scope == :project))
    end

    test "load_all returns only global when project is nil" do
      Store.Memories.init()

      global_mem = AI.Memory.new(%{label: "global", response_template: "Global", scope: :global})
      Store.Memories.create(global_mem)

      loaded = Store.Memories.load_all(nil)

      assert length(loaded) == 1
      assert hd(loaded).scope == :global
    end
  end

  describe "hierarchy operations" do
    test "add_child and get_children" do
      Store.Memories.init()

      parent = AI.Memory.new(%{label: "parent", response_template: "Parent", scope: :global})

      child =
        AI.Memory.new(%{
          label: "child",
          response_template: "Child",
          scope: :global,
          parent_id: parent.id
        })

      Store.Memories.create(parent)
      Store.Memories.create(child)

      assert :ok = Store.Memories.add_child(parent.slug, child.slug, :global)

      children = Store.Memories.get_children(parent.slug, :global)
      assert child.slug in children
    end

    test "remove_child" do
      Store.Memories.init()

      parent = AI.Memory.new(%{label: "parent", response_template: "Parent", scope: :global})
      child = AI.Memory.new(%{label: "child", response_template: "Child", scope: :global})

      Store.Memories.create(parent)
      Store.Memories.create(child)
      Store.Memories.add_child(parent.slug, child.slug, :global)

      assert :ok = Store.Memories.remove_child(parent.slug, child.slug, :global)

      children = Store.Memories.get_children(parent.slug, :global)
      refute child.slug in children
    end

    test "find_parent locates parent by child slug" do
      Store.Memories.init()

      parent = AI.Memory.new(%{label: "parent", response_template: "Parent", scope: :global})
      child = AI.Memory.new(%{label: "child", response_template: "Child", scope: :global})

      Store.Memories.create(parent)
      Store.Memories.create(child)
      Store.Memories.add_child(parent.slug, child.slug, :global)

      # Verify children.log was written
      children_log =
        Path.join([Settings.get_user_home(), ".fnord/memories", parent.slug, "children.log"])

      assert File.exists?(children_log)
      content = File.read!(children_log)
      assert String.contains?(content, child.slug)

      found_parent = Store.Memories.find_parent(child.slug, :global)
      assert found_parent == parent.slug
    end

    test "find_parent returns nil when no parent exists" do
      Store.Memories.init()

      orphan = AI.Memory.new(%{label: "orphan", response_template: "Orphan", scope: :global})
      Store.Memories.create(orphan)

      assert is_nil(Store.Memories.find_parent(orphan.slug, :global))
    end
  end

  describe "delete/2" do
    test "removes memory directory and files" do
      Store.Memories.init()

      memory =
        AI.Memory.new(%{label: "to delete", response_template: "Delete me", scope: :global})

      Store.Memories.create(memory)

      assert Store.Memories.exists?(memory.slug, :global)
      assert :ok = Store.Memories.delete(memory.slug, :global)
      refute Store.Memories.exists?(memory.slug, :global)
    end
  end
end
