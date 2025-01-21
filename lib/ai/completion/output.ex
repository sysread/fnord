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
    if state.log_tool_call_results do
      UI.debug(step)
    end
  end

  def log_tool_call_result(state, step, msg) do
    if state.log_tool_call_results do
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
    AI.Tools.with_args(tool, args, fn args ->
      AI.Tools.on_tool_request(tool, args)
      |> case do
        nil -> state
        {step, msg} -> log_tool_call(state, step, msg)
        step -> log_tool_call(state, step)
      end
    end)
  end

  def on_event(state, :tool_call_result, {tool, args, {:ok, result}}) do
    AI.Tools.with_args(tool, args, fn args ->
      AI.Tools.on_tool_result(tool, args, result)
      |> case do
        nil -> state
        {step, msg} -> log_tool_call_result(state, step, msg)
        step -> log_tool_call_result(state, step)
      end
    end)
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
  def replay_conversation(%{replay_conversation: false} = state), do: state

  def replay_conversation(state) do
    messages = Util.string_keys_to_atoms(state.messages)

    # Make a lookup for tool call args by id
    tool_call_args =
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

    messages
    # Skip the first message, which is the system prompt for the agent
    |> Enum.drop(1)
    |> Enum.each(fn
      %{role: "assistant", content: nil, tool_calls: tool_calls} ->
        tool_calls
        |> Enum.each(fn %{function: %{name: func, arguments: args_json}} ->
          with {:ok, args} <- Jason.decode(args_json) do
            on_event(state, :tool_call, {func, args})
          end
        end)

      %{role: "tool", name: func, tool_call_id: id, content: content} ->
        on_event(state, :tool_call_result, {func, tool_call_args[id], content})

      %{role: "system", content: content} ->
        on_event(state, :tool_call_result, {"planner", %{}, content})

      %{role: "assistant", content: content} ->
        log_assistant_msg(state, content)

      %{role: "user", content: content} ->
        log_user_msg(state, content)
    end)

    state
  end
end
