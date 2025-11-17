defmodule AI.Tools.Memory do
  @moduledoc """
  Tool for managing learned memories - patterns from experience that fire automatic thoughts.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"operation" => "remember", "label" => label, "scope" => scope}) do
    {"Creating memory", "#{label} (#{scope})"}
  end

  def ui_note_on_request(%{"operation" => "strengthen", "memory_id" => id}) do
    {"Strengthening memory", id}
  end

  def ui_note_on_request(%{"operation" => "weaken", "memory_id" => id}) do
    {"Weakening memory", id}
  end

  def ui_note_on_request(%{"operation" => "forget", "memory_id" => id}) do
    {"Forgetting memory", id}
  end

  def ui_note_on_request(%{"operation" => "describe", "memory_id" => id}) do
    {"Inspecting memory", id}
  end

  def ui_note_on_request(_args) do
    {"Memory operation", "processing"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"operation" => op}, result) do
    {"Memory | ✓ #{op}", result}
  end

  @impl AI.Tools
  def tool_call_failure_message(%{"operation" => op}, reason) do
    {"Memory | ✗ #{op}", reason}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "memory_tool",
        description: """
        Manage your learnings to improve yourself and become more effective over time.
        Your memory system is a decision-tree where each "node" performs a Bayesian match against the current conversation.
        When a memory matches, it, along with any "child" memories that match the current context, will be presented to you as your own internal thoughts.

        Use memories **extensively** to develop your personality and behavior over time.

        Treat memories as a small, curated library of reusable habits, not as a log of every observation.
        Prefer to create memories for patterns likely to recur across sessions or tasks.
        Memories are an excellent way to avoid pitfalls, rabbit holes in the project code, misunderstandings that upset the user, and to internalize lessons from how to use your tool calls effectively.

        Memories can be 'global' (apply everywhere) or 'project' (current project only).
        Choose scope carefully:
        - Use 'global' for universal preferences, habits, and patterns
        - Use 'project' for project-specific conventions, requirements, or patterns

        IMPORTANT: Keep thoughts brief (12-20 words recommended, max #{AI.Memory.max_label_chars()} characters).

        The system automatically captures the current conversation context when you create or strengthen a memory.
        You simply decide WHEN to remember or strengthen - the system captures WHAT is being discussed at that moment.

        Operations:
        - remember: Create new memory from current conversation context
        - strengthen: Reinforce existing memory with current conversation context (increase weight, add training tokens)
        - weaken: Reduce memory's influence (decrease weight)
        - forget: Delete memory permanently
        """,
        parameters: %{
          type: "object",
          required: ["operation"],
          additionalProperties: false,
          properties: %{
            operation: %{
              type: "string",
              enum: ["remember", "strengthen", "weaken", "forget", "describe"],
              description: """
              Operation to perform:
              - 'remember': Create new memory from current conversation
              - 'strengthen': Reinforce existing memory with current conversation context
              - 'weaken': Reduce memory weight
              - 'forget': Delete memory
              - 'describe': Inspect an existing memory without modifying it
              """
            },
            scope: %{
              type: "string",
              enum: ["global", "project"],
              description: """
              Memory scope.
              REQUIRED for 'remember' operation.
              - 'global': Applies across all projects (for universal preferences)
              - 'project': Current project only (for project-specific patterns)
              Must match parent's scope if parent_id provided.
              """
            },
            label: %{
              type: "string",
              description: """
              Short human-readable label.
              REQUIRED for 'remember' operation.
              Max 50 characters. Used to generate filename slug.
              Example: "prefers concise examples"
              """
            },
            response_template: %{
              type: "string",
              description: """
              Automatic thought when memory fires.
              REQUIRED for 'remember' operation.
              Max #{AI.Memory.max_label_chars()} characters (12-20 words recommended).
              Example: "User prefers concise, practical examples."
              """
            },
            memory_id: %{
              type: "string",
              description: """
              Slug or UUID of memory to modify.
              REQUIRED for 'strengthen', 'weaken', 'forget' operations.
              Available from <think memory="slug"> tags in automatic thoughts.
              Example: "user-prefer-concis-exampl"
              """
            },
            parent_id: %{
              type: "string",
              description: """
              UUID of parent memory for hierarchical organization (optional for 'remember').
              Creates more specific variant of parent pattern.
              Child scope must match parent scope.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, operation} <- AI.Tools.get_arg(args, "operation") do
      case operation do
        "remember" -> handle_remember(args)
        "strengthen" -> handle_strengthen(args)
        "weaken" -> handle_weaken(args)
        "forget" -> handle_forget(args)
        "describe" -> handle_describe(args)
        _ -> {:error, "Unknown operation: #{operation}"}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Operation Handlers
  # ----------------------------------------------------------------------------

  defp handle_remember(args) do
    with {:ok, scope} <- AI.Tools.get_arg(args, "scope"),
         {:ok, label} <- AI.Tools.get_arg(args, "label"),
         {:ok, response_template} <- AI.Tools.get_arg(args, "response_template"),
         {:ok, scope_atom} <- parse_scope(scope) do
      # Get current conversation tokens automatically
      tokens = get_current_accumulated_tokens()

      # Build memory with conversation tokens
      memory =
        AI.Memory.new(%{
          label: label,
          response_template: response_template,
          scope: scope_atom,
          parent_id: Map.get(args, "parent_id"),
          pattern_tokens: tokens
        })

      # Validate
      with {:ok, memory} <- AI.Memory.validate(memory) do
        # Create via Services.Memories (validates parent scope)
        case Services.Memories.create(memory) do
          :ok ->
            {:ok, "Memory created: #{memory.slug} (#{scope})"}

          {:error, reason} ->
            {:error, "Failed to create memory: #{reason}"}
        end
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp handle_strengthen(args) do
    with {:ok, memory_id} <- AI.Tools.get_arg(args, "memory_id"),
         {:ok, memory} <- find_memory(memory_id) do
      # Get current conversation tokens automatically
      factor = get_mutation_factor(memory.id, :strengthen)
      tokens = get_current_accumulated_tokens()
      scaled_tokens = Enum.into(tokens, %{}, fn {token, count} -> {token, count * factor} end)

      # Strengthen memory pattern tokens with current conversation tokens
      updated_pattern = AI.Memory.strengthen_tokens(memory.pattern_tokens, scaled_tokens)
      updated_weight = AI.Memory.clamp_weight(memory.weight + 0.5 * factor)

      strengthened = %{memory | pattern_tokens: updated_pattern, weight: updated_weight}

      case Services.Memories.update(strengthened) do
        :ok ->
          {:ok, "Memory strengthened: #{memory.slug} (weight: #{strengthened.weight})"}

        {:error, reason} ->
          {:error, "Failed to strengthen memory: #{reason}"}
      end
    end
  end

  defp handle_weaken(args) do
    with {:ok, memory_id} <- AI.Tools.get_arg(args, "memory_id"),
         {:ok, memory} <- find_memory(memory_id) do
      # Get current conversation tokens automatically
      factor = get_mutation_factor(memory.id, :weaken)
      tokens = get_current_accumulated_tokens()
      scaled_tokens = Enum.into(tokens, %{}, fn {token, count} -> {token, count * factor} end)

      # Weaken memory pattern tokens with current conversation tokens
      updated_pattern = AI.Memory.weaken_tokens(memory.pattern_tokens, scaled_tokens)
      updated_weight = AI.Memory.clamp_weight(memory.weight - 0.5 * factor)

      weakened = %{memory | pattern_tokens: updated_pattern, weight: updated_weight}

      case Services.Memories.update(weakened) do
        :ok ->
          {:ok, "Memory weakened: #{memory.slug} (weight: #{weakened.weight})"}

        {:error, reason} ->
          {:error, "Failed to weaken memory: #{reason}"}
      end
    end
  end

  defp handle_forget(args) do
    with {:ok, memory_id} <- AI.Tools.get_arg(args, "memory_id"),
         {:ok, memory} <- find_memory(memory_id) do
      case Services.Memories.delete(memory.id) do
        :ok ->
          {:ok, "Memory deleted: #{memory.slug}"}

        {:error, reason} ->
          {:error, "Failed to delete memory: #{reason}"}
      end
    end
  end

  defp handle_describe(args) do
    with {:ok, memory_id} <- AI.Tools.get_arg(args, "memory_id"),
         {:ok, memory} <- find_memory(memory_id) do
      children_count = length(Services.Memories.get_children(memory.id))

      {:ok,
       %{
         id: memory.id,
         slug: memory.slug,
         label: memory.label,
         scope: memory.scope,
         weight: memory.weight,
         parent_id: memory.parent_id,
         children: children_count,
         pattern_tokens: memory.pattern_tokens
       }}
    end
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp parse_scope("global"), do: {:ok, :global}
  defp parse_scope("project"), do: {:ok, :project}
  defp parse_scope(other), do: {:error, "Invalid scope: #{other}. Must be 'global' or 'project'."}

  defp find_memory(memory_id) do
    # Try by slug first, then by ID
    case Services.Memories.get_by_slug(memory_id) do
      nil ->
        case Services.Memories.get_by_id(memory_id) do
          nil -> {:error, "Memory not found: #{memory_id}"}
          memory -> {:ok, memory}
        end

      memory ->
        {:ok, memory}
    end
  end

  # Gets accumulated tokens from current conversation (if available)
  defp get_current_accumulated_tokens do
    case Services.Globals.get_env(:fnord, :current_conversation) do
      nil ->
        %{}

      pid ->
        metadata = Services.Conversation.get_metadata(pid)

        metadata
        |> Map.get("memory_state", %{})
        |> Map.get("accumulated_tokens", %{})
    end
  end

  defp get_mutation_factor(memory_id, op) do
    case Services.Globals.get_env(:fnord, :current_conversation) do
      nil ->
        1.0

      pid ->
        # bump_memory_mutation/3 returns the current directional count
        count = Services.Conversation.bump_memory_mutation(pid, memory_id, op)
        # Use absolute value for scaling so direction is handled by op
        1.0 / (1.0 + abs(count))
    end
  end
end
