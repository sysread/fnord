defmodule AI.Completion do
  @moduledoc """
  This module sends a request to the model and handles the response. It is able
  to handle tool calls and responses.

  ## Input options

  - `toolbox` - a map of tool names to modules implementing `AI.Tools`; the specs list
    is derived automatically via `AI.Tools.toolbox_to_specs/1`.

  ## Output options

  Output is controlled by the following mechanisms.

  1. `log_msgs` - log messages from the user and assistant as `info`
  2. `log_tool_calls` - log tool calls as `info` and tool call results as `debug`

  `LOGGER_LEVEL` must be set to `debug` to see the output of tool call results.
  """
  defstruct [
    :opts,
    :model,
    :toolbox,
    :specs,
    :log_msgs,
    :log_tool_calls,
    :archive_notes,
    :replay_conversation,
    :usage,
    :messages,
    :tool_call_requests,
    :response
  ]

  @type t :: %__MODULE__{
          opts: Keyword.t(),
          model: String.t(),
          toolbox: AI.Tools.toolbox() | nil,
          specs: list(AI.Tools.tool_spec()) | nil,
          log_msgs: boolean(),
          log_tool_calls: boolean(),
          archive_notes: boolean(),
          replay_conversation: boolean(),
          usage: integer(),
          messages: list(),
          tool_call_requests: list(),
          response: String.t() | nil
        }

  @type response ::
          {:ok, t}
          | {:error, t}
          | {:error, :context_length_exceeded}

  @spec get(Keyword.t()) :: response
  def get(opts) do
    with {:ok, state} <- new(opts) do
      state
      |> AI.Completion.Output.replay_conversation()
      |> send_request()
    end
  end

  def new(opts) do
    with {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, messages} <- Keyword.fetch(opts, :messages) do
      toolbox =
        opts
        |> Keyword.get(:toolbox, nil)
        |> AI.Tools.build_toolbox()

      specs =
        toolbox
        |> Map.values()
        |> Enum.map(& &1.spec())

      log_msgs = Keyword.get(opts, :log_msgs, false)
      replay = Keyword.get(opts, :replay_conversation, true)

      quiet? = Application.get_env(:fnord, :quiet)
      log_tool_calls = Keyword.get(opts, :log_tool_calls, !quiet?)

      archive? = Keyword.get(opts, :archive_notes, false)

      state = %__MODULE__{
        opts: Enum.into(opts, %{}),
        model: model,
        toolbox: toolbox,
        specs: specs,
        log_msgs: log_msgs,
        log_tool_calls: log_tool_calls,
        archive_notes: archive?,
        replay_conversation: replay,
        usage: 0,
        messages: messages,
        tool_call_requests: [],
        response: nil
      }

      {:ok, state}
    end
  end

  def new_from_conversation(conversation, opts) do
    if Store.Project.Conversation.exists?(conversation) do
      {:ok, _ts, msgs} = Store.Project.Conversation.read(conversation)
      new(Keyword.put(opts, :messages, msgs))
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
    AI.CompletionAPI.get(
      state.model,
      state.messages,
      state.specs
    )
    |> handle_response(state)
  end

  defp handle_response({:ok, :msg, response, usage}, state) do
    {:ok,
     %{
       state
       | messages: state.messages ++ [AI.Util.assistant_msg(response)],
         response: response,
         usage: usage
     }}
  end

  defp handle_response({:ok, :tool, tool_calls}, state) do
    %{state | tool_call_requests: tool_calls}
    |> handle_tool_calls()
    |> send_request()
  end

  defp handle_response({:error, :context_length_exceeded}, _state) do
    {:error, :context_length_exceeded}
  end

  defp handle_response({:error, %{http_status: http_status, code: code, message: msg}}, state) do
    error_msg = """
    I encountered an error while processing your request.

    - HTTP Status: #{http_status}
    - Error code: #{code}
    - Message: #{msg}
    """

    {:error, %{state | response: error_msg}}
  end

  defp handle_response({:error, %{http_status: http_status, message: msg}}, state) do
    error_msg = """
    I encountered an error while processing your request.

    - HTTP Status: #{http_status}
    - Message: #{msg}
    """

    {:error, %{state | response: error_msg}}
  end

  defp handle_response({:error, reason}, state) do
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

    {:error, %{state | response: error_msg}}
  end

  # -----------------------------------------------------------------------------
  # Tool calls
  #
  # Note: We intentionally process and log each tool call as its own
  # assistant/tool message pair, rather than grouping multiple tool calls in a
  # single assistant message as the OpenAI API allows. This makes it easier to
  # guarantee tool results always appear immediately after their request,
  # simplifies auditing, and avoids out-of-order response issues. If you need
  # OpenAI-compatible message grouping, refactor here.
  # -----------------------------------------------------------------------------
  defp handle_tool_calls(%{tool_call_requests: tool_calls} = state) do
    {async_calls, serial_calls} =
      Enum.split_with(tool_calls, fn req ->
        AI.Tools.is_async?(req.function.name, state.toolbox)
      end)

    # First handle async tool calls concurrently
    messages =
      async_calls
      |> Util.async_stream(&handle_tool_call(state, &1))
      |> Enum.reduce(state.messages, fn
        {:ok, {:ok, msgs}}, acc -> acc ++ msgs
        _, acc -> acc
      end)

    # Now handle all remaining requests serially and append
    messages =
      Enum.reduce(serial_calls, messages, fn req, acc ->
        {:ok, msgs} = handle_tool_call(state, req)
        acc ++ msgs
      end)

    %{state | tool_call_requests: [], messages: messages}
  end

  def handle_tool_call(state, %{id: id, function: %{name: func, arguments: args_json}}) do
    request = AI.Util.assistant_tool_msg(id, func, args_json)

    with {:ok, output} <- perform_tool_call(state, func, args_json) do
      if state.archive_notes do
        NotesServer.ingest_research(func, args_json, output)
      end

      response = AI.Util.tool_msg(id, func, output)
      {:ok, [request, response]}
    else
      {:error, reason} ->
        oopsie(state, func, args_json, reason)
        response = AI.Util.tool_msg(id, func, reason)
        {:ok, [request, response]}

      {:error, :unknown_tool, tool} ->
        oopsie(state, func, args_json, "Invalid tool #{tool}")

        error = """
        Your attempt to call #{func} failed because the tool '#{tool}' was not found.
        Your tool call request supplied the following arguments: #{args_json}.
        Please consult the specifications for your available tools and use only the tools that are listed.
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, [request, response]}

      {:error, :missing_argument, key} ->
        oopsie(state, func, args_json, "Missing required argument #{key}")

        spec =
          with {:ok, spec} <- AI.Tools.tool_spec(func, state.toolbox),
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

      {:error, :invalid_argument, key} ->
        oopsie(state, func, args_json, "Invalid argument #{key}")

        spec =
          with {:ok, spec} <- AI.Tools.tool_spec(func, state.toolbox),
               {:ok, json} <- Jason.encode(spec) do
            json
          else
            error -> "Error retrieving specification: #{inspect(error)}"
          end

        error = """
        Your attempt to call #{func} failed because it contained an invalid argument or value for '#{key}'.
        Your tool call request supplied the following arguments: #{args_json}.
        The parameter `#{key}` must be a valid value as specified in the tool's specification.
        The correct specification for the tool call is: #{spec}
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, [request, response]}

      {:error, exit_code, msg} when is_integer(exit_code) ->
        oopsie(state, func, args_json, "External process exited with code #{exit_code}: #{msg}")

        error = """
        Your attempt to call #{func} failed because the external process exited with an error.
        Exit code: #{exit_code}
        Error message: #{msg}
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, [request, response]}
    end
  end

  @spec perform_tool_call(t, binary, binary) :: AI.Tools.tool_result()
  defp perform_tool_call(state, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json) do
      AI.Tools.with_args(
        func,
        args,
        fn args ->
          AI.Completion.Output.on_event(state, :tool_call, {func, args})
          result = AI.Tools.perform_tool_call(func, args, state.toolbox)
          AI.Completion.Output.on_event(state, :tool_call_result, {func, args, result})
          result
        end,
        state.toolbox
      )
    end
  end

  @spec oopsie(t, binary, binary, any) :: any
  defp oopsie(state, tool, args_json, reason) do
    AI.Completion.Output.on_event(
      state,
      :tool_call_error,
      {tool, args_json, {:error, reason}}
    )
  end
end
