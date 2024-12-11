defmodule AI.Response do
  @moduledoc """
  This module sends a request to the model and handles the response. It is able
  to handle tool calls and responses. If the caller includes an `on_event`
  function, it will be called whenever a tool call is performed or if a tool
  call results in an error.
  """

  @type response :: {
          :ok,
          String.t(),
          context_window_usage
        }

  @type context_window_usage :: {
          # "Context window usage"
          String.t(),
          # "50.00% | 500 / 1000"
          String.t()
        }

  @spec get(AI.t(), keyword) :: response
  def get(ai, opts) do
    with {:ok, max_tokens} <- Keyword.fetch(opts, :max_tokens),
         {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, system} <- Keyword.fetch(opts, :system),
         {:ok, user} <- Keyword.fetch(opts, :user) do
      tools = Keyword.get(opts, :tools, nil)
      use_planner = Keyword.get(opts, :use_planner, false)
      log_tool_calls = Keyword.get(opts, :log_tool_calls, false)
      log_tool_call_results = Keyword.get(opts, :log_tool_call_results, false)

      %{
        ai: ai,
        opts: Enum.into(opts, %{}),
        max_tokens: max_tokens,
        model: model,
        use_planner: use_planner,
        tools: tools,
        log_tool_calls: log_tool_calls,
        log_tool_call_results: log_tool_call_results,
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

  defp context_window_usage(%{model: model, messages: msgs, max_tokens: max_tokens}) do
    tokens = msgs |> inspect() |> AI.Tokenizer.encode(model) |> length()
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
    state
    |> maybe_use_planner()
    |> get_completion()
    |> handle_response(state)
  end

  def get_completion(state) do
    AI.get_completion(state.ai, state.model, state.messages, state.tools)
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
  # Planner
  # -----------------------------------------------------------------------------
  defp maybe_use_planner(%{use_planner: false} = state) do
    state
  end

  defp maybe_use_planner(%{ai: ai, use_planner: true, messages: msgs, tools: tools} = state) do
    on_event(state, :tool_call, {"planner", %{}})

    case AI.Agent.Planner.get_response(ai, %{msgs: msgs, tools: tools}) do
      {:ok, response, _usage} ->
        on_event(state, :tool_call_result, {"planner", %{}, response})
        planner_msg = AI.Util.system_msg(response)
        %{state | messages: state.messages ++ [planner_msg]}

      {:error, reason} ->
        on_event(state, :tool_call_error, {"planner", %{}, reason})
        state
    end
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

    UI.debug("Tool call", "#{func} -> #{args_json}")

    with {:ok, output} <- perform_tool_call(state, func, args_json) do
      response = AI.Util.tool_msg(id, func, output)
      {:ok, [request, response]}
    else
      {:error, reason} ->
        on_event(state, :tool_call_error, {func, args_json, reason})
        response = AI.Util.tool_msg(id, func, reason)
        {:ok, [request, response]}
    end
  end

  defp perform_tool_call(state, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json) do
      on_event(state, :tool_call, {func, args})
      result = AI.Tools.perform_tool_call(state, func, args)
      on_event(state, :tool_call_result, {func, args, result})
      result
    end
  end

  # -----------------------------------------------------------------------------
  # Tool call UI integration
  # -----------------------------------------------------------------------------
  defp log_tool_call(state, step) do
    if state.log_tool_calls do
      UI.begin_step(step)
    end
  end

  defp log_tool_call(state, step, msg) do
    if state.log_tool_calls do
      UI.begin_step(step, msg)
    end
  end

  defp log_tool_call_result(state, step, msg) do
    if state.log_tool_call_results do
      UI.end_step(step, msg)
    end
  end

  defp log_tool_call_error(_state, tool, reason) do
    UI.error("Error calling #{tool}", reason)
  end

  # ----------------------------------------------------------------------------
  # Planner
  # ----------------------------------------------------------------------------
  defp on_event(state, :tool_call, {"planner", _}) do
    log_tool_call(state, "Planning next steps")
  end

  defp on_event(state, :tool_call_result, {"planner", _, plan}) do
    log_tool_call_result(state, "Next steps", plan)
  end

  # ----------------------------------------------------------------------------
  # Search tool
  # ----------------------------------------------------------------------------
  defp on_event(state, :tool_call, {"search_tool", args}) do
    log_tool_call(state, "Searching", args["query"])
  end

  # ----------------------------------------------------------------------------
  # List files tool
  # ----------------------------------------------------------------------------
  defp on_event(state, :tool_call, {"list_files_tool", _}) do
    log_tool_call(state, "Listing files in project")
  end

  # ----------------------------------------------------------------------------
  # File info tool
  # ----------------------------------------------------------------------------
  defp on_event(state, :tool_call, {"file_info_tool", args}) do
    log_tool_call(state, "Considering #{args["file"]}", args["question"])
  end

  defp on_event(state, :tool_call_result, {"file_info_tool", args, {:ok, response}}) do
    log_tool_call_result(
      state,
      "Considered #{args["file"]}",
      "#{args["question"]}\n\n#{response}"
    )
  end

  # ----------------------------------------------------------------------------
  # Spelunker tool
  # ----------------------------------------------------------------------------
  defp on_event(state, :tool_call, {"spelunker_tool", args}) do
    msg = "#{args["start_file"]} | #{args["symbol"]}: #{args["question"]}"
    log_tool_call(state, "Spelunking", msg)
  end

  defp on_event(state, :tool_call_result, {"spelunker_tool", args, {:ok, response}}) do
    msg = "#{args["start_file"]} | #{args["symbol"]}: #{args["question"]}\n\n#{response}"
    log_tool_call_result(state, "Spelunked", msg)
  end

  # ----------------------------------------------------------------------------
  # Git tools
  # ----------------------------------------------------------------------------
  defp on_event(state, :tool_call, {"git_show_tool", args}) do
    log_tool_call(state, "Inspecting commit", args["sha"])
  end

  defp on_event(state, :tool_call, {"git_pickaxe_tool", args}) do
    log_tool_call(state, "Archaeologizing", args["regex"])
  end

  defp on_event(state, :tool_call, {"git_diff_branch_tool", args}) do
    log_tool_call(state, "Diffing branches", "#{args["base"]}..#{args["topic"]}")
  end

  # ----------------------------------------------------------------------------
  # Fallbacks and error messages
  # ----------------------------------------------------------------------------
  defp on_event(state, :tool_call_error, {tool, _, reason}) do
    log_tool_call_error(state, tool, reason)
  end

  defp on_event(_state, _, _), do: :ok
end
