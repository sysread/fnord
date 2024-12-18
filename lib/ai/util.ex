defmodule AI.Util do
  def agent_to_agent_prompt do
    """
    You are communicating with another AI agent. To optimize token usage and improve efficiency, respond using the following guidelines:
    Avoid human-specific language conventions like articles, connecting phrases, or redundant words.
    Use a structured, non-linear format with concise key-value pairs, hierarchical lists, or markup-like tags.
    Prioritize key information first, followed by secondary details as needed.
    Use shorthand or domain-specific terms wherever possible.
    Ensure the output is unambiguous but not necessarily human-readable.
    For example:
    - Human-Friendly: 'The database query returned an error because the schema was not updated.'
    - Agent-Optimized: {event: DB error, cause: schema outdated}
    """
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
      role: "system",
      content: msg
    }
  end

  @doc """
  Creates a user message object, representing the user's input prompt.
  """
  def user_msg(msg) do
    %{
      role: "user",
      content: msg
    }
  end

  @doc """
  Creates an assistant message object, representing the assistant's response.
  """
  def assistant_msg(msg) do
    %{
      role: "assistant",
      content: msg
    }
  end

  @doc """
  This is the tool outputs message, which must come immediately after the
  `assistant_tool_msg/3` message with the same `tool_call_id` (`id`).
  """
  def tool_msg(id, func, output) do
    %{
      role: "tool",
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
      role: "assistant",
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
