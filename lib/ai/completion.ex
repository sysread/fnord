defmodule AI.Completion do
  @moduledoc """
  This module sends a request to the model and handles the response. It is able
  to handle tool calls and responses.

  ## Output options

  Output is controlled by the following mechanisms.

  1. `log_msgs` - log messages from the user and assistant as `info`
  2. `log_tool_calls` - log tool calls as `info` and tool call results as `debug`

  `LOGGER_LEVEL` must be set to `debug` to see the output of tool call results.
  """
  defstruct [
    :ai,
    :opts,
    :model,
    :tools,
    :log_msgs,
    :log_tool_calls,
    :replay_conversation,
    :messages,
    :tool_call_requests,
    :response
  ]

  @type t :: %__MODULE__{
          ai: AI.t(),
          opts: Keyword.t(),
          model: String.t(),
          tools: list(),
          log_msgs: boolean(),
          log_tool_calls: boolean(),
          replay_conversation: boolean(),
          messages: list(),
          tool_call_requests: list(),
          response: String.t() | nil
        }

  @type response :: {:ok, t}

  @spec get(AI.t(), Keyword.t()) :: response
  def get(ai, opts) do
    with {:ok, state} <- new(ai, opts) do
      state
      |> AI.Completion.Output.replay_conversation()
      |> send_request()
      |> then(&{:ok, &1})
    end
  end

  def new(ai, opts) do
    with {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, messages} <- Keyword.fetch(opts, :messages) do
      tools = Keyword.get(opts, :tools, nil)
      log_msgs = Keyword.get(opts, :log_msgs, false)
      replay = Keyword.get(opts, :replay_conversation, true)

      quiet? = Application.get_env(:fnord, :quiet)
      log_tool_calls = Keyword.get(opts, :log_tool_calls, !quiet?)

      state = %__MODULE__{
        ai: ai,
        opts: Enum.into(opts, %{}),
        model: model,
        tools: tools,
        log_msgs: log_msgs,
        log_tool_calls: log_tool_calls,
        replay_conversation: replay,
        messages: messages,
        tool_call_requests: [],
        response: nil
      }

      {:ok, state}
    end
  end

  def new_from_conversation(conversation, ai, opts) do
    if Store.Project.Conversation.exists?(conversation) do
      {:ok, _ts, msgs} = Store.Project.Conversation.read(conversation)
      new(ai, Keyword.put(opts, :messages, msgs))
    else
      {:error, :conversation_not_found}
    end
  end

  def tools_used(%{messages: messages}) do
    messages
    |> Enum.reduce(%{}, fn
      %{tool_calls: tool_calls}, acc ->
        tool_calls
        |> Enum.reduce(acc, fn
          %{function: %{name: func}}, acc ->
            Map.update(acc, func, 1, &(&1 + 1))
        end)

      _, acc ->
        acc
    end)
  end

  # -----------------------------------------------------------------------------
  # Completion handling
  # -----------------------------------------------------------------------------
  defp send_request(state) do
    state
    |> get_completion()
    |> handle_response()
  end

  def get_completion(state) do
    response = AI.get_completion(state.ai, state.model, state.messages, state.tools)
    {response, state}
  end

  defp handle_response({{:ok, :msg, response}, state}) do
    %{
      state
      | messages: state.messages ++ [AI.Util.assistant_msg(response)],
        response: response
    }
  end

  defp handle_response({{:ok, :tool, tool_calls}, state}) do
    %{state | tool_call_requests: tool_calls}
    |> handle_tool_calls()
    |> send_request()
  end

  defp handle_response({{:error, %{http_status: http_status, code: code, message: msg}}, state}) do
    error_msg = """
    I encountered an error while processing your request.

    - HTTP Status: #{http_status}
    - Error code: #{code}
    - Message: #{msg}
    """

    %{state | response: error_msg}
  end

  defp handle_response({{:error, %{http_status: http_status, message: msg}}, state}) do
    error_msg = """
    I encountered an error while processing your request.

    - HTTP Status: #{http_status}
    - Message: #{msg}
    """

    %{state | response: error_msg}
  end

  defp handle_response({{:error, reason}, state}) do
    reason =
      if is_binary(reason) do
        reason
      else
        inspect(reason, pretty: true)
      end

    error_msg = """
    I encountered an error while processing your request.

    The error message was:

    #{reason}
    """

    %{state | response: error_msg}
  end

  # -----------------------------------------------------------------------------
  # Tool calls
  # -----------------------------------------------------------------------------
  defp handle_tool_calls(%{tool_call_requests: tool_calls} = state) do
    messages =
      tool_calls
      |> Util.async_stream(&handle_tool_call(state, &1))
      |> Enum.reduce(state.messages, fn
        {:ok, {:ok, msgs}}, acc -> acc ++ msgs
        _, acc -> acc
      end)

    %__MODULE__{
      state
      | tool_call_requests: [],
        messages: messages
    }
  end

  def handle_tool_call(state, %{id: id, function: %{name: func, arguments: args_json}}) do
    request = AI.Util.assistant_tool_msg(id, func, args_json)

    with {:ok, output} <- perform_tool_call(state, func, args_json) do
      response = AI.Util.tool_msg(id, func, output)
      {:ok, [request, response]}
    else
      :error ->
        AI.Completion.Output.on_event(state, :tool_call_error, {func, args_json, :error})
        msg = "An error occurred (most likely incorrect arguments)"
        response = AI.Util.tool_msg(id, func, msg)
        {:ok, [request, response]}

      {:error, reason} ->
        AI.Completion.Output.on_event(
          state,
          :tool_call_error,
          {func, args_json, {:error, reason}}
        )

        response = AI.Util.tool_msg(id, func, reason)
        {:ok, [request, response]}

      {:error, :unknown_tool, tool} ->
        AI.Completion.Output.on_event(
          state,
          :tool_call_error,
          {func, args_json, {:error, "Unknown tool: #{tool}"}}
        )

        error = """
        Your attempt to call #{func} failed because the tool '#{tool}' is unknown.
        Your tool call request supplied the following arguments: #{args_json}.
        Please consult the specifications for your available tools and use only the tools that are listed.
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, [request, response]}

      {:error, :missing_argument, key} ->
        AI.Completion.Output.on_event(
          state,
          :tool_call_error,
          {func, args_json, {:error, "Missing required argument: #{key}"}}
        )

        spec =
          with {:ok, spec} <- AI.Tools.tool_spec(func, AI.Tools.all_tools()),
               {:ok, json} <- Jason.encode(spec) do
            json
          else
            error -> "Error retrieving specification: #{inspect(error)}"
          end

        error = """
        Your attempt to call #{func} failed because it was missing a required argument, '#{key}'.
        Your tool call request supplied the following arguments: #{args_json}.
        The parameter `#{key}` must be included and cannot be `null` or an empty string.
        The correct specification for the tool call is: #{spec}
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, [request, response]}

      {:error, exit_code, msg} when is_integer(exit_code) ->
        AI.Completion.Output.on_event(
          state,
          :tool_call_error,
          {func, args_json, {:error, "Exit code: #{exit_code}, Message: #{msg}"}}
        )

        error = """
        The external process returned an error code of #{exit_code} with the message:
        #{msg}
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, [request, response]}
    end
  end

  defp perform_tool_call(state, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json) do
      AI.Tools.with_args(
        func,
        args,
        fn args ->
          AI.Completion.Output.on_event(state, :tool_call, {func, args})

          result =
            AI.Tools.perform_tool_call(state, func, args, AI.Tools.all_tools())
            |> case do
              {:ok, response} when is_binary(response) -> {:ok, response}
              {:ok, response} -> Jason.encode(response)
              :ok -> {:ok, "#{func} completed successfully"}
              other -> other
            end

          AI.Completion.Output.on_event(state, :tool_call_result, {func, args, result})
          result
        end,
        AI.Tools.all_tools()
      )
    end
  end
end
