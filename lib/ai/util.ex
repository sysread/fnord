defmodule AI.Util do
  @role_system "developer"
  @role_user "user"
  @role_assistant "assistant"
  @role_tool "tool"

  def note_format_prompt do
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
    - `<topic>` and `<fact>` are either:
      - Bare string: a short string that does NOT contain `{` or `}`
      - Quoted string: a string bounded by `"`s which may contain escaped `"`
    - Place exactly ONE topic per line.
    - Failure to adhere to the exact format will result in an invalid output.

    Example output:

      {topic dog {fact is mammal} {fact 4 legs} {fact strong sense smell}}
      {topic cat {fact is mammal} {fact 4 legs} {fact assholes}}
      {topic bird {fact is avian} {fact 2 wings} {fact some fly}}
      {topic "sea creature" {fact is aquatic} {fact "can be delicious"} {fact "not always a \"fish\""}}
    """
  end

  @spec validate_notes_string(String.t()) ::
          {:ok, [String.t()]}
          | {:error, :invalid_format}
  def validate_notes_string(notes_string) do
    notes_string
    |> parse_topic_list()
    |> Enum.reduce_while([], fn text, acc ->
      if Store.Project.Note.is_valid_format?(text) do
        {:cont, [text | acc]}
      else
        {:halt, :invalid_format}
      end
    end)
    |> case do
      :invalid_format -> {:error, :invalid_format}
      notes -> {:ok, notes}
    end
  end

  @spec parse_topic_list(String.t()) :: [String.t()]
  def parse_topic_list(input_str) do
    input_str
    |> String.trim("```")
    |> String.trim("'''")
    |> String.trim("\"\"\"")
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
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
    - "Use the file_search_tool to identify examples of existing implementations of X that the user can reference."
      - Agent-Optimized: {search_tool, query X implementation}
    - "The user requested information about 'X', which appears to have multiple meanings in the context of the project."
      - Agent-Optimized: {disambiguate X, respond multiple meaning}
    - "I performed the following tasks: X, Y, and Z
      - Agent-Optimized: {done {task X} {task Y} {task Z}}
    """
  end

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
        if String.starts_with?(content, AI.Agent.Planner.preamble()) do
          [content | acc]
        else
          ["User Query: #{content}" | acc]
        end

      %{role: @role_assistant, content: content}, acc when is_binary(content) ->
        [content | acc]

      # Not supported in reasoning models, but still may be present in older
      # conversations.
      %{role: "system", content: content}, acc ->
        if String.starts_with?(content, AI.Agent.Planner.preamble()) do
          [content | acc]
        else
          acc
        end

      %{role: @role_system, content: content}, acc ->
        if String.starts_with?(content, AI.Agent.Planner.preamble()) do
          [content | acc]
        else
          acc
        end

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
  # Research step counting
  # -----------------------------------------------------------------------------
  @doc """
  Counts the number of steps in the research process. A step is identified
  using planner messages as a proxy for each iteration in the research process.
  This function only counts the steps in the most recent iteration of the
  overall conversation by starting its count from the most recent user message.
  """
  def count_steps(msgs) do
    # msgs is the entire conversation transcript. We're only interested in the
    # most recent steps following the last user message. For example, if the
    # user replied to the original response, we only want to count the steps
    # that followed that reply.
    planner_msgs =
      msgs
      # Start from the end of the conversation.
      |> Enum.reverse()
      # Extract all of the messages up to the last user message. That leaves us
      # with all of the messages that are part of the current research process.
      |> Enum.take_while(fn msg -> !is_user_msg?(msg) end)
      # The planner is called at each step in the process, so we can use that as
      # our canary to identify research "steps".
      |> Enum.filter(&is_step_msg?/1)
      |> Enum.count()

    # -1 for the initial planner message that analyzes the user's query. That
    # msg is immediately followed by the first analysis step we want to count.
    planner_msgs - 1
  end

  defp is_step_msg?(%{role: @role_system, name: "Planner", content: content})
       when is_binary(content) do
    true
  end

  defp is_step_msg?(_), do: false

  defp is_user_msg?(%{role: @role_user, content: content}) when is_binary(content) do
    !String.starts_with?(content, AI.Agent.Planner.preamble())
  end

  defp is_user_msg?(_), do: false

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

  def planner_msg(msg) do
    %{
      role: @role_system,
      content: msg,
      name: "Planner"
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
