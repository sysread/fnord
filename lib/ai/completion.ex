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
  import AI.Util

  defstruct [
    :model,
    :web_search?,
    :response_format,
    :toolbox,
    :specs,
    :log_msgs,
    :log_tool_calls,
    :archive_notes,
    :replay_conversation,
    :name,
    :usage,
    :messages,
    :tool_call_requests,
    :response,
    :compact?,
    :is_compacting?,
    :conversation_pid
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          web_search?: boolean,
          response_format: map | nil,
          toolbox: AI.Tools.toolbox() | nil,
          specs: list(AI.Tools.tool_spec()) | nil,
          log_msgs: boolean(),
          log_tool_calls: boolean(),
          archive_notes: boolean(),
          replay_conversation: boolean(),
          name: String.t() | nil,
          usage: integer(),
          messages: list(AI.Util.msg()),
          tool_call_requests: list(),
          response: String.t() | nil,
          compact?: bool,
          is_compacting?: bool
        }

  @type response ::
          {:ok, t}
          | {:error, t}
          | {:error, binary}
          | {:error, :context_length_exceeded, non_neg_integer}

  @tool_output_preview 1024

  @spec get(Keyword.t()) :: response
  def get(opts) do
    with {:ok, state} <- new(opts) do
      # Note: we do not check the "name" back in. It is associated with this
      # process' pid. If the agent calls `AI.Completion.get/1` again, it will
      # get the same name, maintaining continuity between multiple completion
      # steps.
      state
      |> AI.Completion.Output.replay_conversation()
      |> send_request()
    end
  end

  @spec new(Keyword.t()) :: {:ok, t} | {:error, any}
  def new(opts) do
    with {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, messages} <- Keyword.fetch(opts, :messages) do
      response_format = Keyword.get(opts, :response_format, nil)
      name = Keyword.get(opts, :name, nil)
      compact? = Keyword.get(opts, :compact?, true)
      web_search? = Keyword.get(opts, :web_search?, false)

      toolbox_opt = Keyword.get(opts, :toolbox, nil)

      toolbox =
        cond do
          is_nil(toolbox_opt) -> nil
          is_map(toolbox_opt) && map_size(toolbox_opt) == 0 -> nil
          true -> AI.Tools.build_toolbox(toolbox_opt)
        end

      specs =
        if is_nil(toolbox) do
          nil
        else
          toolbox
          |> Map.values()
          |> Enum.map(& &1.spec())
        end

      log_msgs = Keyword.get(opts, :log_msgs, false)
      replay = Keyword.get(opts, :replay_conversation, true)

      quiet? = Services.Globals.get_env(:fnord, :quiet)
      log_tool_calls = Keyword.get(opts, :log_tool_calls, !quiet?)

      archive? = Keyword.get(opts, :archive_notes, false)
      messages = set_name(messages, name)

      # Back-compat: historically this option key was `:conversation` even
      # though the value was a PID. Prefer the explicit `:conversation_pid`
      # going forward.
      conversation_pid =
        Keyword.get(opts, :conversation_pid) ||
          Keyword.get(opts, :conversation)

      state =
        %__MODULE__{
          model: model,
          web_search?: web_search?,
          response_format: response_format,
          toolbox: toolbox,
          specs: specs,
          log_msgs: log_msgs,
          log_tool_calls: log_tool_calls,
          archive_notes: archive?,
          replay_conversation: replay,
          name: name,
          conversation_pid: conversation_pid,
          usage: 0,
          messages: messages,
          tool_call_requests: [],
          response: nil,
          compact?: compact?,
          is_compacting?: false
        }

      {:ok, state}
    end
  end

  @spec new_from_conversation(Store.Project.Conversation.t(), Keyword.t()) ::
          {:ok, t}
          | {:error, :conversation_not_found}
  def new_from_conversation(conversation, opts) do
    if Store.Project.Conversation.exists?(conversation) do
      with {:ok, %{messages: msgs}} <- Store.Project.Conversation.read(conversation) do
        msgs_atom = Util.string_keys_to_atoms(msgs)
        name = agent_name_from_messages(msgs_atom)

        opts
        |> Keyword.put(:messages, msgs_atom)
        |> then(fn o -> if name, do: Keyword.put(o, :name, name), else: o end)
        |> new()
      end
    else
      {:error, :conversation_not_found}
    end
  end

  @doc """
  Returns a map of tool names to the number of times each tool was called in
  the most recent round of the conversation, starting from the most recent user
  message.
  """
  @spec tools_used(t) :: %{binary => non_neg_integer()}
  def tools_used(%{messages: messages}) do
    # Find the index of the most recent user message in the conversation
    last_user_index =
      messages
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {%{role: "user"}, idx}, _ -> idx
        _, acc -> acc
      end)

    # If no user message exists, return an empty map
    if last_user_index == nil do
      %{}
    else
      # Count tool calls only in messages after the last user message
      messages
      |> Enum.drop(last_user_index + 1)
      |> Enum.reduce(%{}, fn
        %{tool_calls: tool_calls}, acc ->
          tool_calls
          |> Enum.reduce(acc, fn %{function: %{name: func}}, acc ->
            Map.update(acc, func, 1, &(&1 + 1))
          end)

        _, acc ->
          acc
      end)
    end
  end

  # -----------------------------------------------------------------------------
  # Completion handling
  # -----------------------------------------------------------------------------
  defp maybe_apply_interrupts(%{conversation_pid: nil} = state), do: state

  defp maybe_apply_interrupts(%{conversation_pid: pid} = state) do
    pid
    |> Services.Conversation.Interrupts.take_all()
    |> case do
      [] ->
        state

      msgs ->
        new_messages = state.messages ++ msgs
        Services.Conversation.replace_msgs(new_messages, pid)

        Enum.each(msgs, fn %{content: msg} ->
          msg
          |> String.replace_prefix("[User Interjection]", "(rude)")
          |> UI.feedback_user()
        end)

        %{state | messages: new_messages}
    end
  end

  @spec send_request(t) :: response
  defp send_request(state) do
    # Inject any pending user interrupts before calling the model
    state = maybe_apply_interrupts(state)

    AI.CompletionAPI.get(
      state.model,
      state.messages,
      state.specs,
      state.response_format,
      state.web_search?
    )
    |> handle_response(state)
  end

  @spec handle_response({:ok, any} | {:error, any}, t) :: response
  defp handle_response({:ok, :msg, response, usage}, state) do
    {:ok,
     %{
       state
       | messages: state.messages ++ [AI.Util.assistant_msg(response)],
         response: response,
         usage: usage,
         is_compacting?: false
     }}
  end

  defp handle_response({:ok, :tool, tool_calls}, state) do
    state
    |> Map.put(:is_compacting?, false)
    |> Map.put(:tool_call_requests, tool_calls)
    |> handle_tool_calls()
    |> maybe_apply_interrupts()
    |> send_request()
  end

  defp handle_response({:error, :context_length_exceeded, usage}, %{compact?: false}) do
    {:error, :context_length_exceeded, usage}
  end

  defp handle_response(
         {:error, :context_length_exceeded, usage},
         %{messages: msgs, is_compacting?: false} = state
       ) do
    UI.warn("[compaction] Context length exceeded, compacting conversation and retrying...")

    with {:ok, compacted, new_usage} <- AI.Completion.Compaction.compact(msgs) do
      %{state | messages: compacted, usage: new_usage, is_compacting?: true}
      |> send_request()
    else
      {:error, _reason} -> {:error, :context_length_exceeded, usage}
    end
  end

  defp handle_response({:error, :context_length_exceeded, usage}, _state) do
    {:error, :context_length_exceeded, usage}
  end

  defp handle_response({:error, :api_unavailable, reason}, _state) do
    {:error,
     """
     The OpenAI API is currently unavailable. Please try again later.
     Error message: #{reason}
     """}
  end

  defp handle_response({:error, %{http_status: http_status, code: code, message: msg}}, state) do
    error_msg =
      """
      I encountered an error while processing your request.

      - HTTP Status: #{http_status}
      - Error code: #{code}
      - Message: #{msg}
      """

    {:error, %{state | response: error_msg}}
  end

  defp handle_response({:error, %{http_status: http_status, message: msg}}, state) do
    error_msg =
      """
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

    error_msg =
      """
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
    # Deduplicate tool call requests by function name and arguments (canonicalized)
    tool_calls = Enum.uniq_by(tool_calls, &dedupe_key/1)

    {async_calls, serial_calls} =
      Enum.split_with(tool_calls, fn req ->
        AI.Tools.is_async?(req.function.name, state.toolbox)
      end)

    # First handle async tool calls concurrently
    state =
      async_calls
      |> Util.async_stream(
        &handle_tool_call(state, &1),
        ordered: true
      )
      |> collect_tool_call_result_messages(state)

    # Now handle all remaining requests serially
    state =
      serial_calls
      |> Util.async_stream(
        &handle_tool_call(state, &1),
        ordered: true,
        max_concurrency: 1
      )
      |> collect_tool_call_result_messages(state)

    # Clear out the tool call requests and return
    %{state | tool_call_requests: []}
  end

  defp collect_tool_call_result_messages(results, state) do
    messages =
      results
      |> Enum.reduce(state.messages, fn result, acc ->
        case result do
          {:ok, {:ok, req, res}} ->
            acc ++ [req, res]

          {:ok, other} ->
            UI.report_from(
              state.name,
              "Tool call returned unexpected result",
              inspect(other, pretty: true)
            )

            acc

          {:exit, reason} ->
            UI.report_from(
              state.name,
              "Tool call crashed",
              inspect(reason, pretty: true)
            )

            acc

          other ->
            UI.report_from(
              state.name,
              "Tool call produced unknown result",
              inspect(other, pretty: true)
            )

            acc
        end
      end)

    %{state | messages: messages}
  end

  @spec dedupe_key(map()) :: {String.t(), String.t()} | nil
  defp dedupe_key(%{function: %{name: func, arguments: args_json}}) when is_binary(args_json) do
    case Jason.decode(args_json) do
      # Re-encode to get consistent ordering
      {:ok, decoded} -> {func, inspect(decoded, custom_options: [sort_maps: true])}
      # Fallback to raw string if not valid JSON
      _ -> {func, args_json}
    end
  end

  defp dedupe_key(_), do: nil

  @spec handle_tool_call(t, AI.Util.tool_call()) :: {
          :ok,
          AI.Util.tool_request_msg(),
          AI.Util.tool_response_msg()
        }
  def handle_tool_call(state, %{id: id, function: %{name: func, arguments: args_json}}) do
    # --------------------------------------------------------------------------
    # Agents' names are associated with their process ID, and tool call
    # requests and results are reported from within the process that performs
    # the tool call. Because `handle_tool_calls` invokes tools within a
    # separate process, we need to associate the agent's name with the process
    # for the logs to display the correct name.
    #
    # If the tool itself invokes a new agent, that agent will be given a new
    # name in `AI.Agent.get_response/1`.
    # --------------------------------------------------------------------------
    Services.NamePool.associate_name(state.name)

    # Now back to your regularly scheduled programming...
    request = AI.Util.assistant_tool_msg(id, func, args_json)

    with {:ok, output} <- perform_tool_call(state, func, args_json) do
      if state.archive_notes do
        Services.Notes.ingest_research(func, args_json, output)
      end

      response = AI.Util.tool_msg(id, func, output)
      {:ok, request, response}
    else
      {:error, reason} ->
        oopsie(state, func, args_json, reason)
        response = AI.Util.tool_msg(id, func, reason)
        {:ok, request, response}

      {:error, :unknown_tool, tool} ->
        oopsie(state, func, args_json, "Invalid tool #{tool}")

        error = """
        Your attempt to call #{func} failed because the tool '#{tool}' was not found.
        Your tool call request supplied the following arguments: #{args_json}.
        Please consult the specifications for your available tools and use only the tools that are listed.
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, request, response}

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
        {:ok, request, response}

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
        {:ok, request, response}

      {:error, exit_code, msg} when is_integer(exit_code) ->
        oopsie(state, func, args_json, "External process exited with code #{exit_code}: #{msg}")

        error = """
        Your attempt to call #{func} failed because the external process exited with an error.
        Exit code: #{exit_code}
        Error message: #{msg}
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, request, response}
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

          # Execute the tool call and then conditionally offload very large
          # tool outputs to a temp file to avoid keeping gigantic blobs in
          # memory or logs. If offload fails for any reason, we fall back to
          # the original in-memory content.
          result = AI.Tools.perform_tool_call(func, args, state.toolbox)

          result =
            case result do
              {:ok, resp} when is_binary(resp) ->
                {:ok, maybe_offload_tool_output(resp)}

              {:error, reason} when is_binary(reason) ->
                {:error, maybe_offload_tool_output(reason)}

              {:error, code, msg} when is_integer(code) and is_binary(msg) ->
                {:error, code, maybe_offload_tool_output(msg)}

              other ->
                other
            end

          AI.Completion.Output.on_event(state, :tool_call_result, {func, args, result})
          result
        end,
        state.toolbox
      )
    end
  end

  @doc """
  If a tool produced a very large textual output, attempt to write it to a
  temporary file and replace the in-memory content with a short placeholder
  that points to the temp file and includes a preview. Fail silently and return
  the original content on any error.
  """
  def maybe_offload_tool_output(content) when is_binary(content) do
    if String.length(content) <= AI.Util.max_msg_length() do
      content
    else
      preview = content |> :erlang.binary_part(0, @tool_output_preview)

      try do
        tmp = Services.TempFile.mktemp!()

        case File.chmod(tmp, 0o600) do
          :ok -> :ok
          {:error, reason} -> raise "Failed to chmod file #{tmp}: #{inspect(reason)}"
        end

        File.write!(tmp, content)

        "[Large tool output (#{byte_size(content)} bytes) written to #{tmp}. Preview:\n" <>
          preview <> "]"
      rescue
        _ ->
          # On any failure while trying to offload, return the original content
          content
      end
    end
  end

  @spec oopsie(t, binary, binary, any) :: any
  defp oopsie(state, tool, args_json, reason) do
    safe_reason =
      if is_binary(reason) do
        reason
      else
        inspect(reason, pretty: true)
      end

    AI.Completion.Output.on_event(
      state,
      :tool_call_error,
      {tool, args_json, {:error, safe_reason}}
    )
  end

  # Updates the system message that identifies the LLM to itself by name and
  # updates it to use the name provided by the `name` arg, if any.
  defp set_name(messages, nil) do
    set_name(messages, Services.NamePool.default_name())
  end

  defp set_name(messages, name) do
    # Normalize keys so role/content are accessible
    messages = Util.string_keys_to_atoms(messages)

    # Check if any system message already sets the name
    has_name =
      Enum.any?(messages, fn msg ->
        if is_system_msg?(msg) do
          case Regex.run(~r/Your name is .+\./, msg.content) do
            nil -> false
            _ -> true
          end
        else
          false
        end
      end)

    if has_name do
      Enum.map(messages, fn msg ->
        if is_system_msg?(msg) do
          case Regex.run(~r/Your name is .+\./, msg.content) do
            nil -> msg
            _ -> AI.Util.system_msg("Your name is #{name}.")
          end
        else
          msg
        end
      end)
    else
      [AI.Util.system_msg("Your name is #{name}.") | messages]
    end
  end

  defp agent_name_from_messages(messages) do
    Enum.find_value(messages, fn
      %{role: role, content: content} when role in ["system", "developer"] ->
        case Regex.run(~r/^Your name is (.*)\.$/, content) do
          [_, name] -> name
          _ -> nil
        end

      _ ->
        nil
    end)
  end
end
