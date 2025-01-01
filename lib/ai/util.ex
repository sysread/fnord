defmodule AI.Util do
  @role_system "system"
  @role_user "user"
  @role_assistant "assistant"
  @role_tool "tool"

  def notebook_format_prompt do
    """
    Your audience is another AI LLM agent.
    Optimize token usage and efficiency using the following guidelines:
    - Avoid human-specific language conventions like articles, connecting phrases, or redundant words.
    - Use a structured, non-linear format with concise key-value pairs, hierarchical lists, or markup-like tags.
    - Prioritize key information first, followed by secondary details as needed.
    - Use shorthand or domain-specific terms wherever possible.
    - Ensure the output is unambiguous but not necessarily human-readable.

    Respond STRICTLY in the `topic` format below. **Do not deviate.**

    **Required format:**
    - Use this structure: `{topic <topic> {fact <fact>} {fact <fact>} ...}`
    - Place exactly ONE topic per line.
    - Failure to adhere to the exact format will result in an invalid output.

    Example output:

      {topic dog {fact is mammal} {fact 4 legs} {fact strong sense smell}}
      {topic cat {fact is mammal} {fact 4 legs} {fact assholes}}
      {topic bird {fact is avian} {fact 2 wings} {fact some fly}}
    """
  end

  def agent_to_agent_prompt do
    """
    You are communicating with another AI agent.

    Optimize token usage and efficiency using the following guidelines:
    - Avoid human-specific language conventions like articles, connecting phrases, or redundant words.
    - Use a structured, non-linear format with concise key-value pairs, hierarchical lists, or markup-like tags.
    - Prioritize key information first, followed by secondary details as needed.
    - Use shorthand or domain-specific terms wherever possible.
    - Ensure the output is unambiguous but not necessarily human-readable.

    For example:
    - "The database query returned an error because the schema was not updated."
      - Agent-Optimized: {event db error, cause outdated schema}
    - "Use the search_tool to identify examples of existing implementations of X that the user can reference."
      - Agent-Optimized: {search_tool, query X implementation}
    - "The user requested information about 'X', which appears to have multiple meanings in the context of the project."
      - Agent-Optimized: {disambiguate X, respond multiple meaning}
    """
  end

  # Computes the cosine similarity between two vectors
  def cosine_similarity(vec1, vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec1, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec2, 0.0, fn x, acc -> acc + x * x end))

    if magnitude1 == 0.0 or magnitude2 == 0.0 do
      0.0
    else
      dot_product / (magnitude1 * magnitude2)
    end
  end

  def generate_embeddings!(text) do
    AI.new()
    |> AI.get_embeddings(text)
    |> case do
      {:ok, embeddings} ->
        Enum.zip_with(embeddings, &Enum.max/1)

      {:error, reason} ->
        raise "Failed to generate embeddings: #{inspect(reason)}"
    end
  end

  # -----------------------------------------------------------------------------
  # Messages
  # -----------------------------------------------------------------------------

  @doc """
  Creates a system message object, used to define the assistant's behavior for
  the conversation.
  """
  def system_msg(msg) do
    %{
      role: @role_system,
      content: msg
    }
  end

  @doc """
  Creates a user message object, representing the user's input prompt.
  """
  def user_msg(msg) do
    %{
      role: @role_user,
      content: msg
    }
  end

  @doc """
  Creates an assistant message object, representing the assistant's response.
  """
  def assistant_msg(msg) do
    %{
      role: @role_assistant,
      content: msg
    }
  end

  @doc """
  This is the tool outputs message, which must come immediately after the
  `assistant_tool_msg/3` message with the same `tool_call_id` (`id`).
  """
  def tool_msg(id, func, output) do
    %{
      role: @role_tool,
      name: func,
      tool_call_id: id,
      content: output
    }
  end

  @doc """
  This is the tool call message, which must come immediately before the
  `tool_msg/3` message with the same `tool_call_id` (`id`).
  """
  def assistant_tool_msg(id, func, args) do
    %{
      role: @role_assistant,
      content: nil,
      tool_calls: [
        %{
          id: id,
          type: "function",
          function: %{
            name: func,
            arguments: args
          }
        }
      ]
    }
  end
end
