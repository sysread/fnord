defmodule AI.Util do
  # -----------------------------------------------------------------------------
  # Token-based text utilities
  # -----------------------------------------------------------------------------
  def truncate_text(text, max_tokens) do
    if String.length(text) > max_tokens do
      String.slice(text, 0, max_tokens)
    else
      text
    end
  end

  def split_text(input, max_tokens) do
    tokenizer = AI.Tokenizer.get_impl()

    input
    |> tokenizer.encode()
    |> Enum.chunk_every(max_tokens)
    |> Enum.map(&tokenizer.decode(&1))
  end

  # -----------------------------------------------------------------------------
  # Messages
  # -----------------------------------------------------------------------------
  @type msg :: %{
          :content => String.t(),
          :role => String.t(),
          optional(:name) => String.t(),
          optional(:tool_call_id) => String.t()
        }

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
