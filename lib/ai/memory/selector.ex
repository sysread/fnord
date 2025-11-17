defmodule AI.Memory.Selector do
  @moduledoc """
  Evaluation engine for memory-based automatic thoughts.

  Performs best-path hierarchical matching against conversation accumulated tokens.
  Returns formatted <think> blocks to prime the LLM with learned patterns.
  """

  @type tree :: {AI.Memory.t(), [tree]}

  # Configuration from settings or defaults
  @beam_width 2
  @max_thinks 6
  # Hard floor to filter complete garbage
  @minimum_score 0.01
  # Minimum memories needed for statistical threshold
  @min_for_stats 5

  @doc """
  Evaluates memories against conversation state and generates automatic thoughts.

  Returns list of memory trees for formatting into nested <think> blocks.
  """
  @spec evaluate(pid) :: [tree]
  def evaluate(conversation_pid) do
    # Get memories and conversation state
    roots = Services.Memories.get_roots()

    AI.Memory.debug("Evaluating: #{length(roots)} root memories loaded")

    # Skip if no memories loaded
    if Enum.empty?(roots) do
      AI.Memory.debug("No memories loaded, skipping evaluation")
      []
    else
      # Get accumulated tokens from conversation metadata
      accumulated_tokens = get_accumulated_tokens(conversation_pid)
      AI.Memory.debug("Accumulated tokens: #{map_size(accumulated_tokens)} unique tokens")

      if map_size(accumulated_tokens) == 0 do
        AI.Memory.debug("No accumulated tokens, skipping evaluation")

        []
      else
        # Evaluate and generate thought trees
        all_scored = score_all(roots, accumulated_tokens)

        AI.Memory.debug("Total scored: #{length(all_scored)}")

        # Show top 3 scores
        all_scored
        |> Enum.take(3)
        |> Enum.each(fn {mem, score} ->
          AI.Memory.debug("  #{mem.slug}: #{Float.round(score, 4)}")
        end)

        # Apply hybrid threshold selection
        selected = select_firing_memories(all_scored)
        AI.Memory.debug("Selected #{length(selected)} memories to fire")

        selected
        |> Enum.map(&build_tree(&1, accumulated_tokens))
        |> limit_total_nodes(@max_thinks)
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Private Helpers
  # ----------------------------------------------------------------------------

  # Gets accumulated tokens from conversation metadata
  defp get_accumulated_tokens(conversation_pid) do
    # Get metadata from GenServer state (not from disk)
    metadata = Services.Conversation.get_metadata(conversation_pid)

    metadata
    |> Map.get("memory_state", %{})
    |> Map.get("accumulated_tokens", %{})
  end

  # Scores all memories and sorts by score descending (no filtering)
  defp score_all(memories, accumulated_tokens) do
    memories
    |> Util.async_stream(fn memory ->
      score = AI.Memory.compute_score(memory, accumulated_tokens)
      {memory, score}
    end)
    |> Enum.map(fn {:ok, result} -> result end)
    |> Enum.sort_by(fn {_memory, score} -> -score end)
  end

  # Selects which memories should fire using hybrid threshold approach
  defp select_firing_memories(scored_memories) do
    if Enum.empty?(scored_memories) do
      []
    else
      # Step 1: Filter absolute garbage
      viable = Enum.filter(scored_memories, fn {_, score} -> score > @minimum_score end)

      # Step 2: Apply dynamic threshold if enough data
      filtered =
        if length(viable) >= @min_for_stats do
          threshold = find_elbow_threshold(viable)
          Enum.filter(viable, fn {_, score} -> score > threshold end)
        else
          # Not enough memories for statistics, just use minimum
          viable
        end

      # Step 3: Cap at beam_width
      Enum.take(filtered, @beam_width)
    end
  end

  # Finds threshold using elbow/gap method
  defp find_elbow_threshold(scored_memories) do
    scores = Enum.map(scored_memories, fn {_, score} -> score end)

    # Find largest gap between consecutive scores
    gaps =
      scores
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [high, low] -> {high - low, low} end)

    case Enum.max_by(gaps, fn {gap, _} -> gap end, fn -> nil end) do
      {_gap, cutoff} -> cutoff
      # No gap found, use minimum
      nil -> @minimum_score
    end
  end

  # Builds a tree from a scored root by recursively following best child
  defp build_tree({memory, _score}, accumulated_tokens) do
    # Get children and find best match
    children = Services.Memories.get_children(memory.id)

    if Enum.empty?(children) do
      {memory, []}
    else
      # Score children and take best
      best_child =
        children
        |> score_all(accumulated_tokens)
        |> List.first()

      case best_child do
        nil ->
          {memory, []}

        child_with_score ->
          child_tree = build_tree(child_with_score, accumulated_tokens)
          {memory, [child_tree]}
      end
    end
  end

  # Limits total number of nodes across all trees to max_thinks
  defp limit_total_nodes(trees, max_nodes) do
    {limited_trees, _count} =
      Enum.reduce(trees, {[], 0}, fn tree, {acc_trees, count} ->
        nodes_in_tree = count_nodes(tree)

        if count + nodes_in_tree <= max_nodes do
          {[tree | acc_trees], count + nodes_in_tree}
        else
          {acc_trees, count}
        end
      end)

    Enum.reverse(limited_trees)
  end

  # Counts total nodes in a tree
  defp count_nodes({_memory, children}) do
    1 + Enum.sum(Enum.map(children, &count_nodes/1))
  end

  @doc """
  Formats memory trees as an assistant message with nested <think> blocks.
  Returns nil if no trees to inject.
  """
  @spec format_as_message([tree]) :: AI.Util.msg() | nil
  def format_as_message([]), do: nil

  def format_as_message(trees) do
    total_nodes = Enum.sum(Enum.map(trees, &count_nodes/1))

    # Show each memory that's firing
    AI.Memory.debug("Firing #{total_nodes} automatic thoughts (#{length(trees)} chains)")
    Enum.each(trees, fn tree -> debug_tree(tree, 0) end)

    content =
      trees
      |> Enum.map(&format_tree(&1, 0))
      |> Enum.join("\n")

    AI.Util.assistant_msg(content)
  end

  # Debug output for fired memories
  defp debug_tree({memory, children}, depth) do
    indent = String.duplicate("  ", depth)

    AI.Memory.debug(
      "#{indent}└─ #{memory.slug} (#{memory.scope}): \"#{memory.response_template}\""
    )

    Enum.each(children, fn child ->
      debug_tree(child, depth + 1)
    end)
  end

  # Formats a tree as nested <think> tags with proper indentation
  defp format_tree({memory, children}, depth) do
    indent = String.duplicate("  ", depth)
    scope_str = to_string(memory.scope)

    # Build opening tag with attributes
    attrs = ~s(memory="#{memory.slug}" scope="#{scope_str}")

    # Add parent attribute for children (depth > 0)
    attrs =
      if depth > 0 && memory.parent_id do
        parent = Services.Memories.get_by_id(memory.parent_id)
        parent_slug = if parent, do: parent.slug, else: memory.parent_id
        ~s(#{attrs} parent="#{parent_slug}")
      else
        attrs
      end

    # Format children recursively
    if Enum.empty?(children) do
      "#{indent}<think #{attrs}>#{memory.response_template}</think>"
    else
      children_xml =
        children
        |> Enum.map(&format_tree(&1, depth + 1))
        |> Enum.join("\n")

      """
      #{indent}<think #{attrs}>
      #{indent}  #{memory.response_template}
      #{children_xml}
      #{indent}</think>
      """
      |> String.trim_trailing()
    end
  end
end
