defmodule Services.MemoriesTest do
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

    Store.Memories.init()

    # Reload Services.Memories to pick up clean state
    Services.Memories.reload()

    {:ok, project: mock_project("test-memories")}
  end

  describe "GenServer lifecycle" do
    test "loads memories on init" do
      # Create a memory before GenServer starts
      memory = AI.Memory.new(%{label: "preload", response_template: "Preloaded", scope: :global})
      Store.Memories.create(memory)

      # Reload to pick up the memory
      Services.Memories.reload()

      memories = Services.Memories.get_all()
      assert length(memories) >= 1
      assert Enum.any?(memories, &(&1.slug == memory.slug))
    end
  end

  describe "get_all/0 and get_roots/0" do
    test "get_all returns all loaded memories" do
      mem1 = AI.Memory.new(%{label: "mem one", response_template: "One", scope: :global})
      mem2 = AI.Memory.new(%{label: "mem two", response_template: "Two", scope: :global})

      Services.Memories.create(mem1)
      Services.Memories.create(mem2)

      all = Services.Memories.get_all()
      assert length(all) >= 2
      assert Enum.any?(all, &(&1.slug == mem1.slug))
      assert Enum.any?(all, &(&1.slug == mem2.slug))
    end

    test "get_roots returns only memories without parents" do
      root = AI.Memory.new(%{label: "root", response_template: "Root", scope: :global})

      child =
        AI.Memory.new(%{
          label: "child",
          response_template: "Child",
          scope: :global,
          parent_id: root.id
        })

      Services.Memories.create(root)
      Services.Memories.create(child)

      roots = Services.Memories.get_roots()
      assert Enum.any?(roots, &(&1.slug == root.slug))
      refute Enum.any?(roots, &(&1.slug == child.slug))
    end
  end

  describe "get_by_slug/1 and get_by_id/1" do
    test "retrieves memory by slug" do
      memory = AI.Memory.new(%{label: "findme", response_template: "Found", scope: :global})
      Services.Memories.create(memory)

      found = Services.Memories.get_by_slug(memory.slug)
      assert found.id == memory.id
      assert found.label == memory.label
    end

    test "retrieves memory by id" do
      memory = AI.Memory.new(%{label: "findme", response_template: "Found", scope: :global})
      Services.Memories.create(memory)

      found = Services.Memories.get_by_id(memory.id)
      assert found.slug == memory.slug
      assert found.label == memory.label
    end

    test "returns nil for non-existent slug" do
      assert is_nil(Services.Memories.get_by_slug("nonexistent"))
    end

    test "returns nil for non-existent id" do
      assert is_nil(Services.Memories.get_by_id("00000000-0000-0000-0000-000000000000"))
    end
  end

  describe "create/1" do
    test "creates and indexes new memory" do
      memory = AI.Memory.new(%{label: "new mem", response_template: "New", scope: :global})

      assert :ok = Services.Memories.create(memory)
      assert Store.Memories.exists?(memory.slug, :global)

      found = Services.Memories.get_by_id(memory.id)
      assert found.label == "new mem"
    end

    test "validates parent scope matches", ctx do
      Settings.set_project(ctx.project.name)

      parent =
        AI.Memory.new(%{label: "global parent", response_template: "Parent", scope: :global})

      Services.Memories.create(parent)

      # Try to create project-scoped child with global parent
      child =
        AI.Memory.new(%{
          label: "project child",
          response_template: "Child",
          scope: :project,
          parent_id: parent.id
        })

      assert {:error, msg} = Services.Memories.create(child)
      assert msg =~ "scope"
      assert msg =~ "must match"
    end

    test "rejects duplicate slug in same scope" do
      memory1 = AI.Memory.new(%{label: "duplicate", response_template: "First", scope: :global})
      Services.Memories.create(memory1)

      memory2 = AI.Memory.new(%{label: "duplicate", response_template: "Second", scope: :global})
      result = Services.Memories.create(memory2)

      assert {:error, msg} = result
      assert msg =~ "already exists"
      assert msg =~ "duplicate"
      assert msg =~ "Choose a more specific label"
    end

    test "allows same slug in different scopes", ctx do
      Settings.set_project(ctx.project.name)
      Services.Memories.set_project(ctx.project.name)

      global_mem =
        AI.Memory.new(%{label: "same label", response_template: "Global", scope: :global})

      project_mem =
        AI.Memory.new(%{label: "same label", response_template: "Project", scope: :project})

      assert :ok = Services.Memories.create(global_mem)
      assert :ok = Services.Memories.create(project_mem)

      # Both should exist
      assert Services.Memories.get_by_slug(global_mem.slug)
      all = Services.Memories.get_all()
      assert Enum.any?(all, &(&1.scope == :global && &1.slug == global_mem.slug))
      assert Enum.any?(all, &(&1.scope == :project && &1.slug == project_mem.slug))
    end

    test "adds child to parent's children list" do
      parent = AI.Memory.new(%{label: "parent", response_template: "Parent", scope: :global})
      Services.Memories.create(parent)

      child =
        AI.Memory.new(%{
          label: "child",
          response_template: "Child",
          scope: :global,
          parent_id: parent.id
        })

      Services.Memories.create(child)

      # Check that parent's children list was updated
      children_slugs = Store.Memories.get_children(parent.slug, :global)
      assert child.slug in children_slugs
    end
  end

  describe "update/1" do
    test "updates memory and reloads state" do
      memory =
        AI.Memory.new(%{
          label: "update me",
          response_template: "Original",
          scope: :global,
          weight: 1.0
        })

      Services.Memories.create(memory)

      updated = AI.Memory.train(memory, "new pattern", 2.0)
      assert :ok = Services.Memories.update(updated)

      reloaded = Services.Memories.get_by_id(memory.id)
      assert reloaded.weight == 3.0
      assert Map.has_key?(reloaded.pattern_tokens, "new")
      assert Map.has_key?(reloaded.pattern_tokens, "pattern")
    end
  end

  describe "delete/1" do
    test "removes memory from store and state" do
      memory = AI.Memory.new(%{label: "delete me", response_template: "Delete", scope: :global})
      Services.Memories.create(memory)

      assert Services.Memories.get_by_id(memory.id)
      assert :ok = Services.Memories.delete(memory.id)
      assert is_nil(Services.Memories.get_by_id(memory.id))
      refute Store.Memories.exists?(memory.slug, :global)
    end

    test "removes from parent's children list" do
      parent = AI.Memory.new(%{label: "parent", response_template: "Parent", scope: :global})

      child =
        AI.Memory.new(%{
          label: "child",
          response_template: "Child",
          scope: :global,
          parent_id: parent.id
        })

      Services.Memories.create(parent)
      Services.Memories.create(child)

      assert :ok = Services.Memories.delete(child.id)

      children_slugs = Store.Memories.get_children(parent.slug, :global)
      refute child.slug in children_slugs
    end

    test "returns error for non-existent memory" do
      assert {:error, :not_found} = Services.Memories.delete("nonexistent-id")
    end
  end

  describe "get_children/1" do
    test "returns child memories" do
      parent = AI.Memory.new(%{label: "parent", response_template: "Parent", scope: :global})

      child1 =
        AI.Memory.new(%{
          label: "child one",
          response_template: "Child 1",
          scope: :global,
          parent_id: parent.id
        })

      child2 =
        AI.Memory.new(%{
          label: "child two",
          response_template: "Child 2",
          scope: :global,
          parent_id: parent.id
        })

      Services.Memories.create(parent)
      Services.Memories.create(child1)
      Services.Memories.create(child2)

      children = Services.Memories.get_children(parent.id)
      assert length(children) == 2
      assert Enum.any?(children, &(&1.slug == child1.slug))
      assert Enum.any?(children, &(&1.slug == child2.slug))
    end

    test "returns empty list for memory with no children" do
      memory = AI.Memory.new(%{label: "childless", response_template: "No kids", scope: :global})
      Services.Memories.create(memory)

      children = Services.Memories.get_children(memory.id)
      assert children == []
    end

    test "returns empty list for non-existent memory" do
      children = Services.Memories.get_children("nonexistent-id")
      assert children == []
    end
  end

  describe "set_project/1" do
    test "reloads memories when project changes", ctx do
      # Set project first so Services.Memories knows about it
      Settings.set_project(ctx.project.name)
      Services.Memories.set_project(ctx.project.name)

      global_mem = AI.Memory.new(%{label: "global", response_template: "Global", scope: :global})

      project_mem =
        AI.Memory.new(%{label: "project", response_template: "Project", scope: :project})

      Services.Memories.create(global_mem)
      Services.Memories.create(project_mem)

      # Should have both
      all = Services.Memories.get_all()
      assert Enum.any?(all, &(&1.scope == :global))
      assert Enum.any?(all, &(&1.scope == :project))

      # Clear project
      Services.Memories.set_project(nil)

      # Should only have global
      all = Services.Memories.get_all()
      assert Enum.any?(all, &(&1.scope == :global))
      refute Enum.any?(all, &(&1.scope == :project))
    end
  end
end
