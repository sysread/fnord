defmodule AI.Completion.Output do
  # -----------------------------------------------------------------------------
  # UI integration
  # -----------------------------------------------------------------------------
  def log_user_msg(state, msg) do
    if state.log_msgs do
      UI.info("You", msg)
    end
  end

  def log_assistant_msg(state, msg) do
    if state.log_msgs do
      UI.info("Assistant", msg)
    end
  end

  def log_tool_call(state, step) do
    if state.log_tool_calls do
      UI.info(step)
    end
  end

  def log_tool_call(state, step, msg) do
    if state.log_tool_calls do
      UI.info(step, msg)
    end
  end

  def log_tool_call_result(state, step) do
    if state.log_tool_calls do
      UI.debug(step)
    end
  end

  def log_tool_call_result(state, step, msg) do
    if state.log_tool_calls do
      UI.debug(step, msg)
    end
  end

  def log_tool_call_error(_state, tool, reason) do
    UI.error("Error calling #{tool}", reason)
  end

  # -----------------------------------------------------------------------------
  # Tool call logging
  # -----------------------------------------------------------------------------
  def on_event(state, :tool_call, {tool, args}) do
    AI.Tools.on_tool_request(tool, args)
    |> case do
      nil -> state
      {step, msg} -> log_tool_call(state, step, msg)
      step -> log_tool_call(state, step)
    end
  end

  def on_event(state, :tool_call_result, {tool, args, {:ok, result}}) do
    AI.Tools.on_tool_result(tool, args, result)
    |> case do
      nil -> state
      {step, msg} -> log_tool_call_result(state, step, msg)
      step -> log_tool_call_result(state, step)
    end
  end

  def on_event(state, :tool_call_error, {tool, _args_json, {:error, reason}}) do
    reason =
      if is_binary(reason) do
        reason
      else
        inspect(reason, pretty: true)
      end

    log_tool_call_error(state, tool, reason)
  end

  def on_event(_state, _, _), do: :ok

  # ----------------------------------------------------------------------------
  # Continuing a conversation
  # ----------------------------------------------------------------------------
  @doc """
  Replays an earlier conversation identically to the original interaction,
  except that the final response is logged as a typical assistant message, so
  that the conversation may be continued.
  """
  def replay_conversation(%{replay_conversation: false} = state), do: state

  def replay_conversation(state) do
    messages = Util.string_keys_to_atoms(state.messages)

    # Make a lookup for tool call args by id
    tool_call_args = build_tool_call_args(messages)

    messages
    # Skip the first message, which is the system prompt for the agent
    |> Enum.drop(1)
    |> Enum.each(fn msg -> replay_msg(state, msg, tool_call_args) end)

    state
  end

  @doc """
  Replaces the entire conversation, similarly to `replay_conversation/1`, but
  prints the final message to STDOUT, identically to the original interaction.
  This is intended to be used when replaying the entire conversation to
  replicate the original interaction, rather than for the sake of continuing
  the conversation to refine output.
  """
  def replay_conversation_as_output(state) do
    # Retrieve messages and convert to an atom-keyed map, extracting the final
    # message, which is the final response from the assistant.
    {messages, [response]} =
      state.messages
      |> Util.string_keys_to_atoms()
      |> Enum.split(-1)

    # Make a lookup for tool call args by id
    tool_call_args = build_tool_call_args(messages)

    messages
    # Skip the first message, which is the system prompt for the agent
    |> Enum.drop(1)
    |> Enum.each(fn msg ->
      replay_msg(state, msg, tool_call_args)
    end)

    UI.flush()

    # UI outputs to STDERR and the next message is going to STDOUT, so we need
    # to pause to allow the terminal to catch up before printing the final
    # message. This is a shitty, shitty hack, but I haven't found a way to
    # coordinate the two streams.
    Process.sleep(100)

    IO.puts("\n#{response.content}")

    state
  end

  defp replay_msg(state, message, tool_call_args) do
    case message do
      %{role: "assistant", content: nil, tool_calls: tool_calls} ->
        tool_calls
        |> Enum.each(fn %{function: %{name: func, arguments: args_json}} ->
          with {:ok, args} <- Jason.decode(args_json) do
            on_event(state, :tool_call, {func, args})
          end
        end)

      %{role: "tool", name: func, tool_call_id: id, content: content} ->
        on_event(state, :tool_call_result, {func, tool_call_args[id], content})

      %{role: "assistant", content: content} ->
        log_assistant_msg(state, content)

      %{role: "user", content: content} ->
        log_user_msg(state, content)

      _ ->
        :ok
    end
  end

  defp build_tool_call_args(messages) do
    messages
    |> Enum.reduce(%{}, fn msg, acc ->
      case msg do
        %{role: "assistant", content: nil, tool_calls: tool_calls} ->
          tool_calls
          |> Enum.map(fn %{id: id, function: %{arguments: args}} -> {id, args} end)
          |> Enum.into(acc)

        _ ->
          acc
      end
    end)
  end
end
