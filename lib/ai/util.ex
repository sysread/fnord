defmodule AI.Util do
  # ----------------------------------------------------------------------------
  # On average, English words about 4.5 characters long, plus a space or
  # punctuation. OpenAI posits that 1 token ~= 4 characters in English text.
  #
  # We can use these to approximate a reasonable max length for messages to
  # mitigate the risk of a single, new message being added to a conversation
  # that blows so far past the model's context window that it prevents even
  # compaction from working effectively:
  #   - 5 bytes per word * 10,000 words = 50,000 bytes
  #
  # The current crop of models have a context window of 400k tokens:
  #   - 400,000 tokens * 4 bytes per token = 1,600,000 bytes
  #   - 1,600,000 bytes / 50,000 bytes per message = 32 messages
  #
  # That seems like a reasonable baseline threshold to start with.
  # ----------------------------------------------------------------------------
  @max_msg_length 50_000

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

    output = spill_tool_output_if_needed(id, func, output)

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
    |> validate_msg_length()
  end

  @doc """
  A guard to identify system messages.
  """
  defguard is_system_msg?(msg)
           when is_map(msg) and
                  msg.role in [@role_system, "system"]

  # When a tool produces a very large output, writing the entire contents into the
  # conversation can blow past the model's context window. For tool outputs, we
  # instead spill the full content to a temporary file and return a preview plus
  # explicit instructions for using `shell_tool` to inspect the file.
  defp spill_tool_output_if_needed(_id, _func, output) when is_binary(output) do
    if String.length(output) <= @max_msg_length do
      output
    else
      # Use a temp path that the model can reference with shell_tool. We rely
      # on Briefly for atomic, race-safe temp file creation and cleanup when
      # the owning process or BEAM exits.
      with dir when is_binary(dir) <- System.tmp_dir(),
           {:ok, filename} <-
             Services.TempFile.mktemp(
               directory: dir,
               prefix: "fnord-tool-",
               extname: ".log"
             ),
           # Best-effort write; if it fails, we fall back to normal truncation.
           :ok <- File.write(filename, output) do
        bytes = byte_size(output)
        lines = output |> String.split("\n") |> length()

        header = """
        [fnord: tool output truncated]

        Full output saved to: #{filename}
        Size: #{bytes} bytes (#{lines} lines)

        This file will be automatically cleaned up after your next complete response to the user.
        To inspect more of this output, use `shell_tool` with a command like:

        - `cat #{filename}`
        - `sed -n 'START,ENDp' #{filename}`

        --- Begin truncated preview ---
        """

        # Reserve room for the header and a closing footer inside @max_msg_length.
        # This keeps validate_msg_length/1 as a final safety net rather than the
        # primary truncation mechanism for tool outputs.
        header_len = String.length(header)
        footer = "\n--- End truncated preview ---"
        footer_len = String.length(footer)

        # Leave a bit of extra slack so that validate_msg_length/1 is less likely
        # to trim off the footer we add here.
        safety_margin = 200

        max_preview_len = max(@max_msg_length - header_len - footer_len - safety_margin, 0)
        preview = String.slice(output, 0, max_preview_len)
        header <> preview <> footer
      else
        {:error, _reason} ->
          # If we cannot write the tmp file, fall back to the original output and
          # let validate_msg_length/1 handle truncation.
          output
      end
    end
  end

  defp spill_tool_output_if_needed(_id, _func, output), do: output

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
    if String.length(content) > @max_msg_length do
      warning = "(msg truncated due to size)"
      wlen = String.length(warning)
      max = @max_msg_length - wlen
      %{msg | content: String.slice(content, 0, max) <> warning}
    else
      msg
    end
  end

  defp validate_msg_length(msg), do: msg
end
