defmodule AI.Completion.Output do
  @max_tool_lines 10

  # -----------------------------------------------------------------------------
  # UI integration
  # -----------------------------------------------------------------------------
  def log_user_msg(state, msg) do
    if state.log_msgs do
      UI.feedback(:info, "You", msg)
    end
  end

  def log_assistant_msg(%{name: nil} = state, msg) do
    if state.log_msgs do
      UI.feedback(:info, Services.NamePool.default_name(), msg)
    end
  end

  def log_assistant_msg(%{name: name} = state, msg) do
    if state.log_msgs do
      UI.feedback(:info, name, msg)
    end
  end

  def log_tool_call(state, step) do
    if state.log_tool_calls do
      UI.report_from(state.name, step)
    end
  end

  def log_tool_call(state, step, msg) do
    if state.log_tool_calls do
      UI.report_from(state.name, step, Util.truncate(msg, @max_tool_lines))
    end
  end

  def log_tool_call_result(state, step) do
    if state.log_tool_calls do
      UI.report_from(state.name, step)
    end
  end

  def log_tool_call_result(state, step, msg) do
    if state.log_tool_calls do
      UI.report_from(state.name, step, Util.truncate(msg, @max_tool_lines))
    end
  end

  def log_tool_call_error(state, tool, args_json, reason) do
    pretty_args =
      cond do
        is_binary(args_json) ->
          case Jason.decode(args_json) do
            {:ok, decoded} ->
              case Jason.encode(decoded, pretty: true) do
                {:ok, json} -> json
                _ -> inspect(decoded, pretty: true)
              end

            _ ->
              args_json
          end

        true ->
          inspect(args_json, pretty: true)
      end

    name = state.name || "Assistant"

    UI.debug(name, """
    Tool call failed:
    #{tool} :: #{pretty_args}

    #{reason}
    """)
  end

  # -----------------------------------------------------------------------------
  # Tool call logging
  # -----------------------------------------------------------------------------
  def on_event(state, :tool_call, {tool, args}) do
    AI.Tools.on_tool_request(tool, args, state.toolbox)
    |> case do
      nil -> state
      {step, msg} -> log_tool_call(state, step, msg)
      step -> log_tool_call(state, step)
    end
  end

  def on_event(state, :tool_call_result, {tool, args, {:ok, result}}) do
    AI.Tools.on_tool_result(tool, args, result, state.toolbox)
    |> case do
      nil -> state
      {step, msg} -> log_tool_call_result(state, step, msg)
      step -> log_tool_call_result(state, step)
    end
  end

  def on_event(state, :tool_call_error, {tool, args_json, {:error, reason}}) do
    # Decode the arguments JSON, falling back to raw JSON on failure
    args =
      case Jason.decode(args_json) do
        {:ok, decoded} -> decoded
        _ -> args_json
      end

    case AI.Tools.on_tool_error(tool, args, reason, state.toolbox) do
      :ignore ->
        state

      :default ->
        reason_str =
          if is_binary(reason) do
            reason
          else
            inspect(reason, pretty: true)
          end

        log_tool_call_error(state, tool, args_json, reason_str)

      msg when is_binary(msg) ->
        log_tool_call(state, tool, msg)

      {title, detail} when is_binary(title) and is_binary(detail) ->
        log_tool_call(state, title, Util.truncate(detail, @max_tool_lines))

      other ->
        log_tool_call_error(state, tool, args_json, inspect(other, pretty: true))
    end
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

    agent_name = state.name || extract_agent_name(messages)
    state = Map.put(state, :name, agent_name)

    # Make a lookup for tool call args by id
    tool_call_args = build_tool_call_args(messages)

    # The toolbox isn't stored in the saved conversation, so we pass the
    # complete toolbox while replaying.
    all_tools =
      AI.Tools.all_tools()

    messages
    # Skip the first message, which is the system prompt for the agent
    |> Enum.drop(1)
    |> Enum.each(fn msg ->
      state
      |> Map.put(:toolbox, all_tools)
      |> replay_msg(msg, tool_call_args)
    end)

    state
  end

  @doc """
  Replays the entire conversation, similarly to `replay_conversation/1`, but
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

    agent_name = state.name || extract_agent_name(messages)

    state = Map.put(state, :name, agent_name)

    # Make a lookup for tool call args by id
    tool_call_args = build_tool_call_args(messages)

    # The toolbox isn't stored in the saved conversation, so we pass the
    # complete toolbox while replaying.
    all_tools =
      AI.Tools.all_tools()

    messages
    # Skip the first message, which is the system prompt for the agent
    |> Enum.drop(1)
    |> Enum.each(fn msg ->
      state
      |> Map.put(:toolbox, all_tools)
      |> replay_msg(msg, tool_call_args)
    end)

    UI.flush()

    # UI outputs to STDERR and the next message is going to STDOUT, so we need
    # to pause to allow the terminal to catch up before printing the final
    # message. This is a shitty, shitty hack, but I haven't found a way to
    # coordinate the two streams.
    Process.sleep(100)

    UI.say("\n#{response.content}")

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
        if state.log_msgs,
          do:
            UI.feedback_assistant(
              state.name || Services.NamePool.default_name(),
              content
            )

      %{role: "user", content: content} ->
        if state.log_msgs, do: UI.feedback_user(content)

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

  defp extract_agent_name(messages) do
    regex = ~r/^Your name is (.*)\.$/
    default_name = Services.NamePool.default_name()

    # Prefer developer messages
    developer_name =
      messages
      |> Enum.find(fn
        %{role: "developer", content: content} -> Regex.match?(regex, content)
        _ -> false
      end)
      |> case do
        %{content: content} ->
          case Regex.run(regex, content) do
            [_, name] -> name
            _ -> nil
          end

        _ ->
          nil
      end

    if developer_name && developer_name != default_name do
      developer_name
    else
      # Fallback to system messages
      system_name =
        messages
        |> Enum.find(fn
          %{role: "system", content: content} -> Regex.match?(regex, content)
          _ -> false
        end)
        |> case do
          %{content: content} ->
            case Regex.run(regex, content) do
              [_, name] -> name
              _ -> nil
            end

          _ ->
            nil
        end

      if system_name && system_name != default_name do
        system_name
      else
        default_name
      end
    end
  end
end
