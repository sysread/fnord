defmodule AI.Util do
  @max_msg_length 10_485_760

  @role_system "developer"
  @role_user "user"
  @role_assistant "assistant"
  @role_tool "tool"

  @type tool_call :: %{
          id: binary,
          type: binary,
          function: %{name: binary, arguments: binary}
        }

  @type tool_call_parsed :: %{
          id: binary,
          type: binary,
          function: %{name: binary, arguments: map}
        }

  @type content_msg :: %{role: binary, content: binary}

  @type tool_request_msg :: %{
          role: binary,
          content: nil,
          tool_calls: [tool_call_parsed]
        }

  @type tool_response_msg :: %{
          role: binary,
          name: binary,
          tool_call_id: binary,
          content: binary
        }

  @type msg ::
          content_msg
          | tool_request_msg
          | tool_response_msg

  @type msg_list :: [msg]

  # Computes the cosine similarity between two vectors
  @spec cosine_similarity([float], [float]) :: float
  def cosine_similarity(vec1, vec2) do
    if length(vec1) != length(vec2) do
      raise ArgumentError, """
      Vectors must have the same length to compute cosine similarity.
      - Left: #{length(vec1)}
      - Right: #{length(vec2)}
      """
    end

    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec1, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec2, 0.0, fn x, acc -> acc + x * x end))

    if magnitude1 == 0.0 or magnitude2 == 0.0 do
      0.0
    else
      dot_product / (magnitude1 * magnitude2)
    end
  end

  # -----------------------------------------------------------------------------
  # Building transcripts
  # -----------------------------------------------------------------------------
  @doc """
  Builds a "transcript" of the research process by converting the messages into
  text. This is most commonly used to generate a transcript of the research
  performed in a conversation for various agents and tool calls.
  """
  @spec research_transcript([msg]) :: binary
  def research_transcript(msgs) do
    # Make a lookup for tool call args by id
    tool_call_args = build_tool_call_args(msgs)

    msgs
    # Drop all messages until the first user message
    |> Enum.drop_while(&(&1.role != @role_user))
    # Convert messages into text
    |> Enum.reduce([], fn
      %{role: @role_user, content: content}, acc ->
        ["# USER:\n#{content}" | acc]

      %{role: @role_assistant, content: content}, acc when is_binary(content) ->
        # Ignore <think> messages, which are used to indicate the assistant is thinking
        if String.starts_with?(content, "<think>") do
          acc
        else
          ["# ASSISTANT:\n#{content}" | acc]
        end

      # May be present in older conversations.
      %{role: "system", content: _}, acc ->
        acc

      %{role: @role_system, content: _content}, acc ->
        acc

      %{role: @role_tool, tool_call_id: id, name: name, content: content}, acc ->
        args = tool_call_args[id] |> Jason.encode!()

        text = """
        # TOOL CALL

        Performed research using the tool, `#{name}`, with the following arguments:
        `#{args}`

        Result:
        #{content}
        """

        [text | acc]

      _msg, acc ->
        acc
    end)
    |> Enum.reverse()
    |> Enum.join("\n-----\n")
  end

  defp build_tool_call_args(msgs) do
    msgs
    |> Enum.reduce(%{}, fn msg, acc ->
      case msg do
        %{role: @role_assistant, content: nil, tool_calls: tool_calls} ->
          tool_calls
          |> Enum.map(fn %{id: id, function: %{arguments: args}} -> {id, args} end)
          |> Enum.into(acc)

        _ ->
          acc
      end
    end)
  end

  @doc """
  Extracts the user's *most recent* query from the conversation messages.
  """
  @spec user_query([msg]) :: binary | nil
  def user_query(messages) do
    messages
    |> Enum.filter(&(&1.role == @role_user))
    |> List.first()
    |> then(& &1.content)
  end

  # -----------------------------------------------------------------------------
  # Messages
  # -----------------------------------------------------------------------------

  @doc """
  Creates a system message object, used to define the assistant's behavior for
  the conversation.
  """
  @spec system_msg(binary) :: content_msg
  def system_msg(msg) do
    %{role: @role_system, content: msg}
    |> validate_msg_length()
  end

  @doc """
  Creates a user message object, representing the user's input prompt.
  """
  @spec user_msg(binary) :: content_msg
  def user_msg(msg) do
    %{role: @role_user, content: msg}
    |> validate_msg_length()
  end

  @doc """
  Creates an assistant message object, representing the assistant's response.
  """
  @spec assistant_msg(binary) :: content_msg
  def assistant_msg(msg) do
    %{role: @role_assistant, content: msg}
    |> validate_msg_length()
  end

  @doc """
  This is the tool outputs message, which must come immediately after the
  `assistant_tool_msg/3` message with the same `tool_call_id` (`id`).
  """
  @spec tool_msg(binary, binary, any) :: tool_response_msg
  def tool_msg(id, func, output) do
    output =
      if is_binary(output) do
        output
      else
        inspect(output, pretty: true)
      end

    output = """
    #{output}

    Tool call with ID `#{id}` completed using the function `#{func}`.
    """

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
  @spec assistant_tool_msg(binary, binary, binary) :: tool_request_msg
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

  defp validate_msg_length(%{content: content} = msg) when is_binary(content) do
    if byte_size(content) > @max_msg_length do
      warning = "(msg truncated due to size)"
      wlen = byte_size(warning)
      max = @max_msg_length - wlen
      %{msg | content: String.slice(content, 0, max) <> warning}
    else
      msg
    end
  end

  defp validate_msg_length(msg), do: msg
end
