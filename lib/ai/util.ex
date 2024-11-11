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
    Gpt3Tokenizer.encode(input)
    |> Enum.chunk_every(max_tokens)
    |> Enum.map(&Gpt3Tokenizer.decode(&1))
  end

  # -----------------------------------------------------------------------------
  # Models
  # -----------------------------------------------------------------------------
  @type model :: %{
          name: String.t(),
          context_window: non_neg_integer
        }

  def model(:smart), do: {:ok, %{name: "gpt-4o", context_window: 128_000}}
  def model(:fast), do: {:ok, %{name: "gpt-4o-mini", context_window: 128_000}}
  def model(:embed), do: {:ok, %{name: "text-embedding-3-large", context_window: 8192}}

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
  def system_msg(msg), do: OpenaiEx.ChatMessage.system(msg)

  @doc """
  Creates a user message object, representing the user's input prompt.
  """
  def user_msg(msg), do: OpenaiEx.ChatMessage.user(msg)

  @doc """
  Creates an assistant message object, representing the assistant's response.
  """
  def assistant_msg(msg), do: OpenaiEx.ChatMessage.assistant(msg)

  @doc """
  This is the tool outputs message, which must come immediately after the
  `assistant_tool_msg/3` message with the same `tool_call_id` (`id`).
  """
  def tool_msg(id, func, output), do: OpenaiEx.ChatMessage.tool(id, func, output)

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
