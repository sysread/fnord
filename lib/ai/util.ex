defmodule AI.Util do
  @role_system "developer"
  @role_user "user"
  @role_assistant "assistant"
  @role_tool "tool"

  # Computes the cosine similarity between two vectors
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
  def research_transcript(msgs) do
    # Make a lookup for tool call args by id
    tool_call_args = build_tool_call_args(msgs)

    msgs
    # Remove the first message, which is the orchestrating agent's system prompt
    |> Enum.drop(1)
    # Convert messages into text
    |> Enum.reduce([], fn
      %{role: @role_user, content: content}, acc ->
        ["User Query: #{content}" | acc]

      %{role: @role_assistant, content: content}, acc when is_binary(content) ->
        # Ignore <think> messages, which are used to indicate the assistant is thinking
        if String.starts_with?(content, "<think>") && String.ends_with?(content, "</think>") do
          acc
        else
          [content | acc]
        end

      # May be present in older conversations.
      %{role: "system", content: _}, acc ->
        acc

      %{role: @role_system, content: _content}, acc ->
        acc

      %{role: @role_tool, tool_call_id: id, name: name, content: content}, acc ->
        args = tool_call_args[id] |> Jason.encode!()

        text = """
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
