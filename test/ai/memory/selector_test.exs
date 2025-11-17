defmodule AI.Memory.SelectorTest do
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

    {:ok, project: mock_project("test-agent-memories")}
  end

  describe "evaluate/1" do
    test "returns empty list when no memories exist" do
      {:ok, pid} = Services.Conversation.start_link()
      Services.Conversation.append_msg(AI.Util.user_msg("Hello world"), pid)

      thoughts = AI.Memory.Selector.evaluate(pid)
      assert thoughts == []
    end

    test "returns empty list when accumulated_tokens empty" do
      # Create a memory but no conversation messages
      memory =
        AI.Memory.new(%{
          label: "test",
          response_template: "Test response",
          scope: :global,
          pattern_tokens: %{"hello" => 1}
        })

      Services.Memories.create(memory)

      {:ok, pid} = Services.Conversation.start_link()

      thoughts = AI.Memory.Selector.evaluate(pid)
      assert thoughts == []
    end

    test "fires memory that matches conversation tokens" do
      # Create memory that will match
      # Use similar frequencies to what will be in accumulated tokens
      memory =
        AI.Memory.new(%{
          label: "hello matcher",
          response_template: "User said hello",
          scope: :global,
          pattern_tokens: %{"hello" => 3, "world" => 3},
          # Boost weight to ensure it fires
          weight: 5.0
        })

      Services.Memories.create(memory)

      # Create conversation with matching content (repeat to boost frequency)
      {:ok, pid} = Services.Conversation.start_link()

      Services.Conversation.append_msg(
        AI.Util.user_msg("Hello world hello world hello world!"),
        pid
      )

      # Save to persist metadata with accumulated_tokens
      Services.Conversation.save(pid)

      trees = AI.Memory.Selector.evaluate(pid)
      assert length(trees) > 0

      # Format and check output
      message = AI.Memory.Selector.format_as_message(trees)
      assert message.content =~ memory.slug
      assert message.content =~ memory.response_template
      assert message.content =~ ~s(scope="global")
    end

    test "selects best memories even with low absolute scores" do
      # Create memory with pattern that won't match well
      # But with hybrid threshold, it should still fire if it's the best available
      memory =
        AI.Memory.new(%{
          label: "low scorer",
          response_template: "This has low score",
          scope: :global,
          pattern_tokens: %{"elephant" => 10, "giraffe" => 5}
        })

      Services.Memories.create(memory)

      {:ok, pid} = Services.Conversation.start_link()
      Services.Conversation.append_msg(AI.Util.user_msg("cat dog bird"), pid)
      Services.Conversation.save(pid)

      trees = AI.Memory.Selector.evaluate(pid)
      # With hybrid threshold and only 1 memory, it should fire
      # (beam_width=2, we have 1 memory, it's above minimum_score)
      assert length(trees) > 0
    end

    test "takes top N roots by beam_width" do
      # Create 3 memories with different match strengths
      mem1 =
        AI.Memory.new(%{
          label: "strong match",
          response_template: "Strong",
          scope: :global,
          pattern_tokens: %{"cat" => 100, "dog" => 100}
        })

      mem2 =
        AI.Memory.new(%{
          label: "medium match",
          response_template: "Medium",
          scope: :global,
          pattern_tokens: %{"cat" => 10, "bird" => 10}
        })

      mem3 =
        AI.Memory.new(%{
          label: "weak match",
          response_template: "Weak",
          scope: :global,
          pattern_tokens: %{"cat" => 1}
        })

      Services.Memories.create(mem1)
      Services.Memories.create(mem2)
      Services.Memories.create(mem3)

      {:ok, pid} = Services.Conversation.start_link()
      Services.Conversation.append_msg(AI.Util.user_msg("cat dog cat dog cat dog"), pid)
      Services.Conversation.save(pid)

      thoughts = AI.Memory.Selector.evaluate(pid)

      # Should only fire top 2 (beam_width = 2)
      # Strong and medium should fire, weak should not
      assert length(thoughts) <= 2
    end

    test "builds hierarchical chains from parent to child with nested XML" do
      # Create parent and child memories with boosted weights
      parent =
        AI.Memory.new(%{
          label: "parent",
          response_template: "Parent thought",
          scope: :global,
          pattern_tokens: %{"test" => 3},
          weight: 5.0
        })

      Services.Memories.create(parent)

      child =
        AI.Memory.new(%{
          label: "child",
          response_template: "Child thought",
          scope: :global,
          parent_id: parent.id,
          pattern_tokens: %{"test" => 3, "exampl" => 3},
          weight: 5.0
        })

      Services.Memories.create(child)

      {:ok, pid} = Services.Conversation.start_link()

      Services.Conversation.append_msg(
        AI.Util.user_msg("test example test example test example"),
        pid
      )

      Services.Conversation.save(pid)

      trees = AI.Memory.Selector.evaluate(pid)
      assert length(trees) > 0

      # Format and check nested structure
      message = AI.Memory.Selector.format_as_message(trees)
      content = message.content

      # Should have parent memory tag
      assert content =~ ~s(memory="#{parent.slug}")
      assert content =~ ~s(scope="global")
      assert content =~ parent.response_template

      # Should have nested child memory tag
      assert content =~ ~s(memory="#{child.slug}")
      assert content =~ ~s(parent="#{parent.slug}")
      assert content =~ child.response_template

      # Child should be nested inside parent (check XML structure)
      # Parent opening tag should appear before child
      parent_idx = String.split(content, ~s(memory="#{parent.slug}")) |> hd() |> String.length()
      child_idx = String.split(content, ~s(memory="#{child.slug}")) |> hd() |> String.length()
      assert child_idx > parent_idx
    end

    test "respects max_thinks limit" do
      # Create deep hierarchy that exceeds max_thinks
      parent =
        AI.Memory.new(%{
          label: "level 0",
          response_template: "Level 0",
          scope: :global,
          pattern_tokens: %{"test" => 10},
          weight: 5.0
        })

      Services.Memories.create(parent)

      # Create chain of children
      _prev_id =
        Enum.reduce(1..10, parent.id, fn i, prev_id ->
          child =
            AI.Memory.new(%{
              label: "level #{i}",
              response_template: "Level #{i}",
              scope: :global,
              parent_id: prev_id,
              pattern_tokens: %{"test" => 10},
              weight: 5.0
            })

          Services.Memories.create(child)
          child.id
        end)

      {:ok, pid} = Services.Conversation.start_link()
      Services.Conversation.append_msg(AI.Util.user_msg("test test test"), pid)
      Services.Conversation.save(pid)

      trees = AI.Memory.Selector.evaluate(pid)

      # Count total nodes across all trees
      total_nodes =
        trees
        |> Enum.map(fn tree ->
          count_tree_nodes(tree)
        end)
        |> Enum.sum()

      # Should be limited to max_thinks (6)
      assert total_nodes <= 6
    end
  end

  # Helper to count nodes in a tree
  defp count_tree_nodes({_memory, children}) do
    1 + Enum.sum(Enum.map(children, &count_tree_nodes/1))
  end

  describe "format_as_message/1" do
    test "returns nil for empty trees" do
      assert is_nil(AI.Memory.Selector.format_as_message([]))
    end

    test "formats trees as nested <think> tags" do
      # Create memories via Services so lookups work
      parent_mem =
        AI.Memory.new(%{
          label: "parent",
          response_template: "Parent thought",
          scope: :global
        })

      Services.Memories.create(parent_mem)

      child_mem =
        AI.Memory.new(%{
          label: "child",
          response_template: "Child thought",
          scope: :global,
          parent_id: parent_mem.id
        })

      Services.Memories.create(child_mem)

      # Build tree structure manually
      tree = {parent_mem, [{child_mem, []}]}

      message = AI.Memory.Selector.format_as_message([tree])

      assert message.role == "assistant"
      assert message.content =~ ~s(memory="#{parent_mem.slug}")
      assert message.content =~ ~s(memory="#{child_mem.slug}")
      assert message.content =~ ~s(parent="#{parent_mem.slug}")
      assert message.content =~ "Parent thought"
      assert message.content =~ "Child thought"
    end
  end
end
