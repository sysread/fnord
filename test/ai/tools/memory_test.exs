defmodule AI.Tools.MemoryTest do
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

    {:ok, project: mock_project("test-memory-tool")}
  end

  describe "remember operation" do
    test "creates new global memory" do
      args = %{
        "operation" => "remember",
        "scope" => "global",
        "label" => "test memory",
        "response_template" => "Test response"
      }

      result = AI.Tools.Memory.call(args)
      assert {:ok, msg} = result
      assert msg =~ "Memory created"
      assert msg =~ "global"

      # Verify memory was created
      memories = Services.Memories.get_all()
      assert length(memories) > 0
      created = hd(memories)
      assert created.label == "test memory"
      assert created.scope == :global
      # Pattern tokens will be empty since no conversation is set up
      assert is_map(created.pattern_tokens)
    end

    test "creates project memory when project selected", ctx do
      Settings.set_project(ctx.project.name)
      Services.Memories.set_project(ctx.project.name)

      args = %{
        "operation" => "remember",
        "scope" => "project",
        "label" => "project memory unique",
        "response_template" => "Project response"
      }

      result = AI.Tools.Memory.call(args)
      assert {:ok, msg} = result
      assert msg =~ "Memory created"
      assert msg =~ "project"

      created = Services.Memories.get_all() |> Enum.find(&(&1.scope == :project))
      assert created.label == "project memory unique"
    end

    test "validates response_template length" do
      long_response = String.duplicate("a", AI.Memory.max_label_chars() + 1)

      args = %{
        "operation" => "remember",
        "scope" => "global",
        "label" => "test",
        "response_template" => long_response
      }

      result = AI.Tools.Memory.call(args)
      assert {:error, msg} = result
      assert msg =~ "response_template exceeds"
      assert msg =~ "brief"
    end

    test "validates parent scope matches", ctx do
      Settings.set_project(ctx.project.name)
      Services.Memories.set_project(ctx.project.name)

      # Create global parent
      parent =
        AI.Memory.new(%{
          label: "global parent",
          response_template: "Parent",
          scope: :global
        })

      Services.Memories.create(parent)

      # Try to create project child with global parent
      args = %{
        "operation" => "remember",
        "scope" => "project",
        "label" => "project child",
        "response_template" => "Child",
        "parent_id" => parent.id
      }

      result = AI.Tools.Memory.call(args)
      assert {:error, msg} = result
      assert msg =~ "scope"
      assert msg =~ "must match"
    end

    test "creates child memory with matching parent scope" do
      parent =
        AI.Memory.new(%{
          label: "parent",
          response_template: "Parent",
          scope: :global
        })

      Services.Memories.create(parent)

      args = %{
        "operation" => "remember",
        "scope" => "global",
        "label" => "child",
        "response_template" => "Child",
        "parent_id" => parent.id
      }

      result = AI.Tools.Memory.call(args)
      assert {:ok, _msg} = result

      # Verify child was added to parent
      children = Services.Memories.get_children(parent.id)
      assert length(children) == 1
    end

    test "rejects duplicate label (slug collision)" do
      args1 = %{
        "operation" => "remember",
        "scope" => "global",
        "label" => "duplicate label",
        "response_template" => "First"
      }

      assert {:ok, _msg} = AI.Tools.Memory.call(args1)

      # Try to create another with same label
      args2 = %{
        "operation" => "remember",
        "scope" => "global",
        "label" => "duplicate label",
        "response_template" => "Second"
      }

      result = AI.Tools.Memory.call(args2)
      assert {:error, msg} = result
      assert msg =~ "already exists"
      assert msg =~ "duplicate label"
      assert msg =~ "Choose a more specific label"
    end
  end

  describe "strengthen operation" do
    test "increases weight" do
      memory =
        AI.Memory.new(%{
          label: "strengthen me",
          response_template: "Original",
          scope: :global,
          pattern_tokens: %{"original" => 1},
          weight: 1.0
        })

      Services.Memories.create(memory)

      args = %{
        "operation" => "strengthen",
        "memory_id" => memory.slug
      }

      result = AI.Tools.Memory.call(args)
      assert {:ok, msg} = result
      assert msg =~ "strengthened"
      # weight increased by 0.5
      assert msg =~ "1.5"

      updated = Services.Memories.get_by_slug(memory.slug)
      assert updated.weight == 1.5
      # Original pattern tokens should still be present
      assert Map.has_key?(updated.pattern_tokens, "original")
    end

    test "updates pattern_tokens sublinearly with context tokens" do
      # Set up a memory with an existing token
      memory =
        AI.Memory.new(%{
          label: "sublinear",
          response_template: "Test",
          scope: :global,
          pattern_tokens: %{"a" => 3.0}
        })

      Services.Memories.create(memory)

      # Simulate a conversation where accumulated_tokens has a:2 and d:4
      {:ok, pid} = Services.Conversation.start_link()

      # Manually inject memory_state into metadata to control tokens
      metadata = %{"memory_state" => %{"accumulated_tokens" => %{"a" => 2, "d" => 4}}}
      :sys.replace_state(pid, fn state -> %{state | metadata: metadata} end)

      args = %{
        "operation" => "strengthen",
        "memory_id" => memory.slug
      }

      assert {:ok, _msg} = AI.Tools.Memory.call(args)

      updated = Services.Memories.get_by_slug(memory.slug)

      # Existing token "a" should NOT have decreased
      assert updated.pattern_tokens["a"] >= 3.0

      # New token "d" should have been added with a count close to its raw count
      assert updated.pattern_tokens["d"] >= 4.0
    end

    test "accepts memory ID or slug" do
      memory =
        AI.Memory.new(%{
          label: "test",
          response_template: "Test",
          scope: :global
        })

      Services.Memories.create(memory)

      # By slug
      args_slug = %{
        "operation" => "strengthen",
        "memory_id" => memory.slug
      }

      assert {:ok, msg} = AI.Tools.Memory.call(args_slug)
      assert msg =~ "strengthened"

      # By ID
      args_id = %{
        "operation" => "strengthen",
        "memory_id" => memory.id
      }

      assert {:ok, msg} = AI.Tools.Memory.call(args_id)
      assert msg =~ "strengthened"
    end
  end

  describe "describe operation" do
    test "returns structured info for an existing memory" do
      memory =
        AI.Memory.new(%{
          label: "inspect me",
          response_template: "Test",
          scope: :global,
          pattern_tokens: %{"token" => 1},
          weight: 2.0
        })

      Services.Memories.create(memory)

      args = %{
        "operation" => "describe",
        "memory_id" => memory.slug
      }

      result = AI.Tools.Memory.call(args)
      assert {:ok, info} = result
      assert info.id == memory.id
      assert info.slug == memory.slug
      assert info.label == memory.label
      assert info.scope == memory.scope
      assert info.weight == memory.weight
      assert is_integer(info.children)
      assert info.pattern_tokens == memory.pattern_tokens
    end

    test "returns error for non-existent memory" do
      args = %{
        "operation" => "describe",
        "memory_id" => "nonexistent"
      }

      result = AI.Tools.Memory.call(args)
      assert {:error, msg} = result
      assert msg =~ "not found"
    end
  end

  describe "weaken operation" do
    test "decreases weight" do
      memory =
        AI.Memory.new(%{
          label: "weaken me",
          response_template: "Test",
          scope: :global,
          weight: 5.0
        })

      Services.Memories.create(memory)

      args = %{
        "operation" => "weaken",
        "memory_id" => memory.slug
      }

      result = AI.Tools.Memory.call(args)
      assert {:ok, msg} = result
      assert msg =~ "weakened"
      # weight decreased by 0.5
      assert msg =~ "4.5"

      updated = Services.Memories.get_by_slug(memory.slug)
      assert updated.weight == 4.5
    end

    test "decrements pattern_tokens sublinearly and removes tokens below 1" do
      memory =
        AI.Memory.new(%{
          label: "weaken sublinear",
          response_template: "Test",
          scope: :global,
          pattern_tokens: %{"a" => 2.0, "b" => 0.9}
        })

      Services.Memories.create(memory)

      # Simulate conversation with accumulated_tokens that include existing and non-existing tokens
      {:ok, pid} = Services.Conversation.start_link()

      metadata = %{"memory_state" => %{"accumulated_tokens" => %{"a" => 1, "c" => 5}}}
      :sys.replace_state(pid, fn state -> %{state | metadata: metadata} end)

      args = %{
        "operation" => "weaken",
        "memory_id" => memory.slug
      }

      assert {:ok, _msg} = AI.Tools.Memory.call(args)

      updated = Services.Memories.get_by_slug(memory.slug)

      # "a" should still be present and not increased above the original
      assert updated.pattern_tokens["a"] <= 2.0
      assert updated.pattern_tokens["a"] >= 1.0

      # "b" should be unchanged because it was not present in the weakening context
      assert Map.has_key?(updated.pattern_tokens, "b")

      # "c" should be ignored for weakening because it was not in the pattern
      refute Map.has_key?(updated.pattern_tokens, "c")
    end
  end

  describe "forget operation" do
    test "deletes memory" do
      memory =
        AI.Memory.new(%{
          label: "forget me",
          response_template: "Goodbye",
          scope: :global
        })

      Services.Memories.create(memory)

      assert Services.Memories.get_by_slug(memory.slug)

      args = %{
        "operation" => "forget",
        "memory_id" => memory.slug
      }

      result = AI.Tools.Memory.call(args)
      assert {:ok, msg} = result
      assert msg =~ "deleted"
      assert is_nil(Services.Memories.get_by_slug(memory.slug))
    end

    test "returns error for non-existent memory" do
      args = %{
        "operation" => "forget",
        "memory_id" => "nonexistent"
      }

      result = AI.Tools.Memory.call(args)
      assert {:error, msg} = result
      assert msg =~ "not found"
    end
  end

  describe "error handling" do
    test "requires scope for remember" do
      args = %{
        "operation" => "remember",
        "label" => "test",
        "response_template" => "Test"
      }

      result = AI.Tools.Memory.call(args)
      assert {:error, :missing_argument, "scope"} = result
    end

    test "requires label for remember" do
      args = %{
        "operation" => "remember",
        "scope" => "global",
        "response_template" => "Test"
      }

      result = AI.Tools.Memory.call(args)
      assert {:error, :missing_argument, "label"} = result
    end

    test "requires memory_id for strengthen/weaken/forget" do
      args_strengthen = %{"operation" => "strengthen"}
      assert {:error, :missing_argument, "memory_id"} = AI.Tools.Memory.call(args_strengthen)

      args_weaken = %{"operation" => "weaken"}
      assert {:error, :missing_argument, "memory_id"} = AI.Tools.Memory.call(args_weaken)

      args_forget = %{"operation" => "forget"}
      assert {:error, :missing_argument, "memory_id"} = AI.Tools.Memory.call(args_forget)
    end

    test "rejects invalid scope" do
      args = %{
        "operation" => "remember",
        "scope" => "invalid",
        "label" => "test",
        "response_template" => "Test"
      }

      result = AI.Tools.Memory.call(args)
      assert {:error, msg} = result
      assert msg =~ "Invalid scope"
    end
  end
end
