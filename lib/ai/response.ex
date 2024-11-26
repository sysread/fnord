defmodule AI.Response do
  def get(ai, opts) do
    with {:ok, max_tokens} <- Keyword.fetch(opts, :max_tokens),
         {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, system} <- Keyword.fetch(opts, :system),
         {:ok, user} <- Keyword.fetch(opts, :user) do
      tools = Keyword.get(opts, :tools, nil)
      on_event = Keyword.get(opts, :on_event, fn _, _ -> :ok end)

      %{
        ai: ai,
        opts: Enum.into(opts, %{}),
        max_tokens: max_tokens,
        model: model,
        tools: tools,
        on_event: on_event,
        messages: [AI.Util.system_msg(system), AI.Util.user_msg(user)],
        tool_call_requests: [],
        response: nil
      }
      |> send_request()
      |> then(fn state ->
        {:ok, state.response, context_window_usage(state)}
      end)
    end
  end

  defp context_window_usage(%{messages: msgs, max_tokens: max_tokens}) do
    tokens = msgs |> inspect() |> Gpt3Tokenizer.encode() |> length()
    pct = tokens / max_tokens * 100.0
    pct_str = Number.Percentage.number_to_percentage(pct, precision: 2)
    tokens_str = Number.Delimit.number_to_delimited(tokens, precision: 0)
    max_tokens_str = Number.Delimit.number_to_delimited(max_tokens, precision: 0)
    {"Context window usage", "#{pct_str} | #{tokens_str} / #{max_tokens_str}"}
  end

  # -----------------------------------------------------------------------------
  # Response handling
  # -----------------------------------------------------------------------------
  defp send_request(state) do
    AI.get_completion(state.ai, state.model, state.messages, state.tools)
    |> handle_response(state)
  end

  defp handle_response({:ok, :msg, response}, state) do
    %{state | response: response}
  end

  defp handle_response({:ok, :tool, tool_calls}, state) do
    %{state | tool_call_requests: tool_calls}
    |> handle_tool_calls()
    |> send_request()
  end

  defp handle_response({:error, reason}, state) do
    reason =
      if is_binary(reason) do
        reason
      else
        inspect(reason)
      end

    %{
      state
      | response: """
        I encountered an error while processing your request.
        The error message was:

        #{reason}
        """
    }
  end

  # -----------------------------------------------------------------------------
  # Tool calls
  # -----------------------------------------------------------------------------
  defp handle_tool_calls(%{tool_call_requests: tool_calls} = state) do
    {:ok, queue} = Queue.start_link(&handle_tool_call(state, &1))

    outputs =
      tool_calls
      |> Queue.map(queue)
      |> Enum.flat_map(fn {:ok, msgs} -> msgs end)

    Queue.shutdown(queue)
    Queue.join(queue)

    %{
      state
      | tool_call_requests: [],
        messages: state.messages ++ outputs
    }
  end

  def handle_tool_call(state, %{id: id, function: %{name: func, arguments: args_json}}) do
    request = AI.Util.assistant_tool_msg(id, func, args_json)

    UI.debug("TOOL CALL ID=#{id} FUNC=#{func} ARGS=#{args_json}")

    with {:ok, output} <- perform_tool_call(state, func, args_json) do
      response = AI.Util.tool_msg(id, func, output)
      {:ok, [request, response]}
    else
      {:error, reason} ->
        state.on_event.(:tool_call_error, {func, args_json, reason})
        response = AI.Util.tool_msg(id, func, reason)
        {:ok, [request, response]}
    end
  end

  # -----------------------------------------------------------------------------
  # Tool call outputs
  # -----------------------------------------------------------------------------
  defp perform_tool_call(state, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json) do
      state.on_event.(:tool_call, {func, args})
      perform_tool_call(state, func, args)
    end
  end

  defp perform_tool_call(state, "search_tool", args) do
    AI.Tools.Search.call(state, args)
  end

  defp perform_tool_call(state, "list_files_tool", args) do
    AI.Tools.ListFiles.call(state, args)
  end

  defp perform_tool_call(state, "file_info_tool", args) do
    AI.Tools.FileInfo.call(state, args)
  end

  defp perform_tool_call(state, "spelunker_tool", args) do
    AI.Tools.Spelunker.call(state, args)
  end

  defp perform_tool_call(state, "git_pickaxe_tool", args) do
    AI.Tools.GitPickaxe.call(state, args)
  end

  defp perform_tool_call(state, "git_show_tool", args) do
    AI.Tools.GitShow.call(state, args)
  end

  defp perform_tool_call(state, "outline_tool", args) do
    AI.Tools.Outline.call(state, args)
  end

  defp perform_tool_call(_state, func, _args) do
    {:error, :unhandled_tool_call, func}
  end
end
