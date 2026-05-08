defmodule AI.Completion.Output do
  import AI.Util,
    only: [is_assistant_msg?: 1, is_system_msg?: 1, is_tool_call_msg?: 1, is_tool_msg?: 1, is_user_msg?: 1]

  @max_tool_lines 10

  # -----------------------------------------------------------------------------
  # UI integration
  # -----------------------------------------------------------------------------
  def log_user_msg(state, msg) do
    if state.log_msgs do
      UI.feedback_user(msg)
    end
  end

  def log_assistant_msg(%{name: nil} = state, msg) do
    if state.log_msgs do
      UI.feedback_assistant(Services.NamePool.default_name(), msg)
    end
  end

  def log_assistant_msg(%{name: name} = state, msg) do
    if state.log_msgs do
      UI.feedback_assistant(name, msg)
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

  # Log a tool call error. The reason is always emitted at debug level. The
  # raw args JSON is only dumped to stderr when FNORD_DEBUG_TOOL_CALLS is set,
  # bypassing Logger entirely so large payloads aren't truncated.
  def log_tool_call_error(state, tool, args_json, reason) do
    name = state.name || "Assistant"

    UI.debug(name, """
    Tool call failed: #{tool}
    #{reason}
    """)

    maybe_dump_tool_call_args(tool, args_json)
  end

  # When FNORD_DEBUG_TOOL_CALLS is set, pretty-print the full args JSON to
  # stderr, bypassing Logger and the formatter so nothing gets truncated.
  defp maybe_dump_tool_call_args(tool, args_json) do
    if System.get_env("FNORD_DEBUG_TOOL_CALLS") do
      pretty =
        with true <- is_binary(args_json),
             {:ok, decoded} <- SafeJson.decode(args_json),
             {:ok, json} <- SafeJson.encode(decoded, pretty: true) do
          json
        else
          _ when is_binary(args_json) -> args_json
          _ -> inspect(args_json, pretty: true)
        end

      border = "# " <> String.duplicate("-", 77)

      dump = """
      #{border}
      # Tool call args (#{tool})
      #{border}
      #{pretty}
      #{border}
      """

      IO.puts(:stderr, dump)
      UI.Tee.write([dump, "\n"])
    end
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
      case SafeJson.decode(args_json) do
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

    # Mark toolbox as replay to bypass validation in AI.Tools.on_tool_request
    replay_tools = Map.put(all_tools, "__replay__", true)

    messages
    # Skip the first message, which is the system prompt for the agent
    |> Enum.drop(1)
    |> Enum.each(fn msg ->
      state
      |> Map.put(:toolbox, replay_tools)
      |> replay_msg(msg, tool_call_args)
    end)

    state
  end

  @doc """
  Replays the entire conversation, similarly to `replay_conversation/1`, while
  rendering the final assistant response to STDOUT in the same shape the user
  would receive from the CLI.

  Piped output stays plain for copy/paste safety. Interactive terminal output
  adds the same kind of framed emphasis used by other prominent terminal
  sections so the replay ends with a clear handoff from the agent to the user.
  """
  def replay_conversation_as_output(state) do
    # Retrieve messages and convert to an atom-keyed map, extracting the final
    # message, which is the final response from the assistant.
    all = Util.string_keys_to_atoms(state.messages)

    case Enum.split(all, -1) do
      {messages, [response]} ->
        do_replay(state, messages, response)

      # An empty or malformed saved conversation (e.g. truncated write, manual
      # edit) has nothing to replay. Surface the empty case rather than
      # crashing with MatchError on the split.
      _ ->
        UI.warn("[replay] conversation has no messages to replay")
        state
    end
  end

  defp do_replay(state, messages, response) do
    agent_name = state.name || extract_agent_name(messages)

    state = Map.put(state, :name, agent_name)

    # Make a lookup for tool call args by id
    tool_call_args = build_tool_call_args(messages)

    # The toolbox isn't stored in the saved conversation, so we pass the
    # complete toolbox while replaying.
    all_tools =
      AI.Tools.all_tools()

    # Mark toolbox as replay to bypass validation in AI.Tools.on_tool_request
    replay_tools = Map.put(all_tools, "__replay__", true)

    messages
    # Skip the first message, which is the system prompt for the agent
    |> Enum.drop(1)
    |> Enum.each(fn msg ->
      state
      |> Map.put(:toolbox, replay_tools)
      |> replay_msg(msg, tool_call_args)
    end)

    UI.flush()

    # UI outputs to STDERR and the next message is going to STDOUT, so we need
    # to pause to allow the terminal to catch up before printing the final
    # message. This is a shitty, shitty hack, but I haven't found a way to
    # coordinate the two streams.
    Process.sleep(100)

    output = format_final_response_output(response.content, agent_name, UI.stdout_tty?())
    IO.write(:stdio, output)

    state
  end

  defp replay_msg(state, message, tool_call_args) do
    cond do
      is_tool_call_msg?(message) ->
        Enum.each(message.tool_calls, fn %{function: %{name: func, arguments: args_json}} ->
          with {:ok, args} <- SafeJson.decode(args_json) do
            on_event(state, :tool_call, {func, args})
          end
        end)

      is_tool_msg?(message) ->
        %{name: func, tool_call_id: id, content: content} = message
        on_event(state, :tool_call_result, {func, tool_call_args[id], content})

      is_assistant_msg?(message) ->
        log_assistant_msg(state, message.content)

      is_user_msg?(message) ->
        log_user_msg(state, message.content)

      true ->
        :ok
    end
  end

  # Formats the final assistant response for the terminal. Piped output stays
  # plain so saved or redirected text remains clean, while interactive terminal
  # output gets a framed banner naming the agent before the response body.
  defp format_final_response_output(content, agent_name, true) do
    content
    |> final_response_with_banner(agent_name)
    |> UI.format()
  end

  defp format_final_response_output(content, _agent_name, false) do
    "\n#{content}\n"
  end

  # Wraps the final assistant response in the same visual framing used by other
  # prominent terminal sections so the end of the replay reads like a deliberate
  # handoff from the agent to the user.
  defp final_response_with_banner(content, agent_name) do
    [
      "\n",
      response_banner_separator(),
      "\n",
      response_banner_title(agent_name),
      "\n",
      response_banner_separator(),
      "\n\n",
      content,
      "\n"
    ]
    |> IO.iodata_to_binary()
  end

  # Builds the separator line used around the final response banner.
  defp response_banner_separator do
    IO.ANSI.format([:cyan, String.duplicate("─", 60), :reset], true)
  end

  # Builds the banner title for the final response using the responding agent's
  # name.
  defp response_banner_title(agent_name) do
    title = " ◆ #{agent_name}'s Response ◆ "
    IO.ANSI.format([:cyan_background, :black, :bright, title, :reset], true)
  end

  defp build_tool_call_args(messages) do
    Enum.reduce(messages, %{}, fn msg, acc ->
      if is_tool_call_msg?(msg) do
        msg.tool_calls
        |> Enum.map(fn %{id: id, function: %{arguments: args}} -> {id, args} end)
        |> Enum.into(acc)
      else
        acc
      end
    end)
  end

  defp extract_agent_name(messages) do
    regex = ~r/^Your name is (.*)\.$/
    default_name = Services.NamePool.default_name()

    # System / developer prompts both carry the agent name. Either role
    # is treated as equivalent here - which one shows up depends on the
    # active provider.
    name =
      Enum.find_value(messages, fn msg ->
        if is_system_msg?(msg) do
          case Regex.run(regex, Map.get(msg, :content, "")) do
            [_, name] -> name
            _ -> nil
          end
        end
      end)

    if is_binary(name) and name != default_name do
      name
    else
      default_name
    end
  end
end
