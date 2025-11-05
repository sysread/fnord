defmodule AI.Responses do
  @moduledoc """
  Mirror of `AI.Completion` backed by the OpenAI Responses API.
  Behavior and tuple contracts are identical; only the HTTP client differs.
  """

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
          compact?: boolean,
          conversation_pid: pid | nil
        }

  @type response ::
          {:ok, t}
          | {:error, t}
          | {:error, binary}
          | {:error, :context_length_exceeded, non_neg_integer}

  @compact_keep_rounds 2
  @compact_target_pct 0.6

  @spec get(Keyword.t()) :: response
  def get(opts) do
    with {:ok, state} <- new(opts) do
      state
      |> AI.Responses.Output.replay_conversation()
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
          is_map(toolbox_opt) and map_size(toolbox_opt) == 0 -> nil
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
      conversation_pid = Keyword.get(opts, :conversation)

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
          compact?: compact?
        }

      {:ok, state}
    end
  end

  @spec new_from_conversation(Store.Project.Conversation.t(), Keyword.t()) ::
          {:ok, t} | {:error, :conversation_not_found}
  def new_from_conversation(conversation, opts) do
    if Store.Project.Conversation.exists?(conversation) do
      with {:ok, _ts, msgs} <- Store.Project.Conversation.read(conversation) do
        opts
        |> Keyword.put(:messages, msgs)
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
    last_user_index =
      messages
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {%{role: "user"}, idx}, _ -> idx
        _, acc -> acc
      end)

    if last_user_index == nil do
      %{}
    else
      messages
      |> Enum.drop(last_user_index + 1)
      |> Enum.reduce(%{}, fn
        %{tool_calls: tool_calls}, acc ->
          Enum.reduce(tool_calls, acc, fn
            # Nested and flattened tool call entries
            %{function: %{name: func}}, acc_inner ->
              Map.update(acc_inner, func, 1, &(&1 + 1))

            %{name: func}, acc_inner ->
              Map.update(acc_inner, func, 1, &(&1 + 1))

            _, acc_inner ->
              acc_inner
          end)

        _, acc ->
          acc
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Request/Response orchestration
  # ---------------------------------------------------------------------------

  @doc false
  @spec send_request(t) :: response
  defp send_request(state) do
    state = maybe_apply_interrupts(state)

    AI.ResponsesAPI.get(
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
    updated = %{
      state
      | messages: state.messages ++ [AI.Util.assistant_msg(response)],
        response: response,
        usage: usage
    }

    updated = maybe_compact(updated)
    {:ok, updated}
  end

  defp handle_response({:ok, :tool, tool_calls}, state) do
    state
    |> Map.put(:tool_call_requests, tool_calls)
    |> handle_tool_calls()
    |> maybe_apply_interrupts()
    |> send_request()
  end

  defp handle_response({:error, :context_length_exceeded, usage}, state) do
    if state.compact? do
      %{state | usage: usage}
      |> maybe_compact(true)
      |> send_request()
    else
      {:error, :context_length_exceeded, usage}
    end
  end

  defp handle_response({:error, :api_unavailable, reason}, _state) do
    {:error,
     "The OpenAI API is currently unavailable. Please try again later.\nError message: #{reason}"}
  end

  defp handle_response({:error, %{http_status: http_status, code: code, message: msg}}, state) do
    {:error,
     %{
       state
       | response:
           "I encountered an error while processing your request.\n\n- HTTP Status: #{http_status}\n- Error code: #{code}\n- Message: #{msg}\n"
     }}
  end

  defp handle_response({:error, %{http_status: http_status, message: msg}}, state) do
    {:error,
     %{
       state
       | response:
           "I encountered an error while processing your request.\n\n- HTTP Status: #{http_status}\n- Message: #{msg}\n"
     }}
  end

  defp handle_response({:error, reason}, state) do
    safe = if is_binary(reason), do: reason, else: inspect(reason, pretty: true)

    {:error,
     %{
       state
       | response:
           "I encountered an error while processing your request.\n\nThe error message was:\n\n#{safe}\n"
     }}
  end

  # ---------------------------------------------------------------------------
  # Tool calls
  # ---------------------------------------------------------------------------

  defp handle_tool_calls(%{tool_call_requests: tool_calls} = state) do
    tool_calls = Enum.uniq_by(tool_calls, &dedupe_key/1)

    {async_calls, serial_calls} =
      Enum.split_with(tool_calls, fn req ->
        AI.Tools.is_async?(req.name, state.toolbox)
      end)

    state =
      async_calls
      |> Util.async_stream(&handle_tool_call(state, &1), ordered: true)
      |> collect_tool_call_result_messages(state)

    state =
      serial_calls
      |> Util.async_stream(&handle_tool_call(state, &1), ordered: true, max_concurrency: 1)
      |> collect_tool_call_result_messages(state)

    %{state | tool_call_requests: []}
  end

  defp collect_tool_call_result_messages(results, state) do
    messages =
      Enum.reduce(results, state.messages, fn
        {:ok, {:ok, req, res}}, acc ->
          acc ++ [req, res]

        {:ok, other}, acc ->
          UI.report_from(
            state.name,
            "Tool call returned unexpected result",
            inspect(other, pretty: true)
          )

          acc

        {:exit, reason}, acc ->
          UI.report_from(state.name, "Tool call crashed", inspect(reason, pretty: true))
          acc

        other, acc ->
          UI.report_from(
            state.name,
            "Tool call produced unknown result",
            inspect(other, pretty: true)
          )

          acc
      end)

    %{state | messages: messages}
  end

  @spec dedupe_key(map()) :: {String.t(), String.t()} | nil
  # Extracts the dedupe key (function name and arguments) from a flattened tool call map
  defp dedupe_key(%{name: func, arguments: args_json}) when is_binary(args_json) do
    case Jason.decode(args_json) do
      {:ok, decoded} -> {func, inspect(decoded, custom_options: [sort_maps: true])}
      _ -> {func, args_json}
    end
  end

  defp dedupe_key(_), do: nil

  @spec handle_tool_call(t, map()) :: {:ok, AI.Util.tool_request_msg(), AI.Util.tool_response_msg()}
  # Handles an individual tool call request given the flattened call map
  def handle_tool_call(state, %{id: id, name: func, arguments: args_json}) do
    Services.NamePool.associate_name(state.name)

    request = AI.Util.assistant_tool_msg(id, func, args_json)

    with {:ok, output} <- perform_tool_call(state, func, args_json) do
      if state.archive_notes, do: Services.Notes.ingest_research(func, args_json, output)
      response = AI.Util.tool_msg(id, func, output)
      {:ok, request, response}
    else
      {:error, reason} ->
        oopsie(state, func, args_json, reason)
        {:ok, request, AI.Util.tool_msg(id, func, reason)}

      {:error, :unknown_tool, tool} ->
        oopsie(state, func, args_json, "Invalid tool #{tool}")

        error =
          "Your attempt to call #{func} failed because the tool '#{tool}' was not found.\nYour tool call request supplied the following arguments: #{args_json}.\nPlease consult the specifications for your available tools and use only the tools that are listed.\n"

        {:ok, request, AI.Util.tool_msg(id, func, error)}

      {:error, :missing_argument, key} ->
        oopsie(state, func, args_json, "Missing required argument #{key}")

        spec =
          with {:ok, spec} <- AI.Tools.tool_spec(func, state.toolbox),
               {:ok, json} <- Jason.encode(spec) do
            json
          else
            error -> "Error retrieving specification: #{inspect(error)}"
          end

        error =
          "Your attempt to call #{func} failed because it was missing a required argument, '#{key}'.\nYour tool call request supplied the following arguments: #{args_json}.\nThe parameter `#{key}` must be included and cannot be `null` or an empty string.\nThe correct specification for the tool call is: #{spec}\n"

        {:ok, request, AI.Util.tool_msg(id, func, error)}

      {:error, :invalid_argument, key} ->
        oopsie(state, func, args_json, "Invalid argument #{key}")

        spec =
          with {:ok, spec} <- AI.Tools.tool_spec(func, state.toolbox),
               {:ok, json} <- Jason.encode(spec) do
            json
          else
            error -> "Error retrieving specification: #{inspect(error)}"
          end

        error =
          "Your attempt to call #{func} failed because it contained an invalid argument or value for '#{key}'.\nYour tool call request supplied the following arguments: #{args_json}.\nThe parameter `#{key}` must be a valid value as specified in the tool's specification.\nThe correct specification for the tool call is: #{spec}\n"

        {:ok, request, AI.Util.tool_msg(id, func, error)}

      {:error, exit_code, msg} when is_integer(exit_code) ->
        oopsie(state, func, args_json, "External process exited with code #{exit_code}: #{msg}")

        error =
          "Your attempt to call #{func} failed because the external process exited with an error.\nExit code: #{exit_code}\nError message: #{msg}\n"

        {:ok, request, AI.Util.tool_msg(id, func, error)}
    end
  end

  @spec perform_tool_call(t, binary, binary) :: AI.Tools.tool_result()
  defp perform_tool_call(state, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json) do
      AI.Tools.with_args(
        func,
        args,
        fn args ->
          AI.Responses.Output.on_event(state, :tool_call, {func, args})
          result = AI.Tools.perform_tool_call(func, args, state.toolbox)
          AI.Responses.Output.on_event(state, :tool_call_result, {func, args, result})
          result
        end,
        state.toolbox
      )
    end
  end

  defp oopsie(state, tool, args_json, reason) do
    safe = if is_binary(reason), do: reason, else: inspect(reason, pretty: true)
    AI.Responses.Output.on_event(state, :tool_call_error, {tool, args_json, {:error, safe}})
  end

  # ---------------------------------------------------------------------------
  # Compaction & interrupts
  # ---------------------------------------------------------------------------

  defp maybe_compact(state, force \\ false)
  defp maybe_compact(%{usage: 0} = state, false), do: state
  defp maybe_compact(state, true), do: AI.Responses.Compaction.full_compact(state)

  defp maybe_compact(%{usage: usage, model: %{context: context}} = state, false) do
    used_pct = Float.round(usage / context * 100, 1)

    if used_pct > 80 do
      opts = %{keep_rounds: @compact_keep_rounds, target_pct: @compact_target_pct}
      AI.Responses.Compaction.partial_compact(state, opts)
    else
      state
    end
  end

  defp maybe_apply_interrupts(%{conversation_pid: nil} = state), do: state

  defp maybe_apply_interrupts(%{conversation_pid: pid} = state) do
    interrupts = Services.Conversation.Interrupts.take_all(pid)

    case interrupts do
      [] ->
        state

      msgs ->
        new_messages = state.messages ++ msgs
        Services.Conversation.replace_msgs(new_messages, pid)
        UI.info("The LLM will see your message after the current step completes.")
        %{state | messages: new_messages}
    end
  end

  defp set_name(messages, nil), do: set_name(messages, Services.NamePool.default_name())

  defp set_name(messages, name) do
    has_name? =
      Enum.any?(messages, fn
        %{role: "system", content: content} -> content =~ ~r/Your name is .+\./
        _ -> false
      end)

    if has_name? do
      Enum.map(messages, fn
        %{role: "system", content: content} ->
          if content =~ ~r/Your name is .+\./ do
            %{role: "system", content: "Your name is #{name}."}
          else
            %{role: "system", content: content}
          end

        msg ->
          msg
      end)
    else
      [%{role: "system", content: "Your name is #{name}."} | messages]
    end
  end
end
