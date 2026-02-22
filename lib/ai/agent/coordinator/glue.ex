defmodule AI.Agent.Coordinator.Glue do
  @moduledoc """
  Integration code for the Coordinator and AI.Tools, AI.Completion, etc.
  """

  @type t :: AI.Agent.Coordinator.t()
  @type state :: AI.Agent.Coordinator.state()

  # ----------------------------------------------------------------------------
  # Tool box
  # ----------------------------------------------------------------------------
  @spec get_tools(t) :: AI.Tools.toolbox()
  def get_tools(%{edit?: true}) do
    AI.Tools.basic_tools()
    |> AI.Tools.with_task_tools()
    |> AI.Tools.with_rw_tools()
    |> AI.Tools.with_coding_tools()
    |> AI.Tools.with_web_tools()
  end

  def get_tools(_) do
    AI.Tools.basic_tools()
    |> AI.Tools.with_task_tools()
    |> AI.Tools.with_web_tools()
  end

  # ----------------------------------------------------------------------------
  # Completion
  # ----------------------------------------------------------------------------
  @spec get_completion(t, boolean) :: state
  def get_completion(state, replay \\ false) do
    msgs = Services.Conversation.get_messages(state.conversation_pid)

    # Save the current conversation to the store for crash resilience
    with {:ok, conversation} <- Services.Conversation.save(state.conversation_pid) do
      UI.report_step("Conversation state saved", conversation.id)
    else
      {:error, reason} ->
        UI.error("Failed to save conversation state", inspect(reason))
    end

    # Invoke completion once, ensuring conversation state is included
    AI.Agent.get_completion(state.agent,
      log_msgs: true,
      log_tool_calls: true,
      archive_notes: true,
      compact?: true,
      replay_conversation: replay,
      conversation_pid: state.conversation_pid,
      model: state.model,
      toolbox: AI.Agent.Coordinator.Glue.get_tools(state),
      messages: msgs
    )
    |> case do
      {:ok, %{response: response, messages: new_msgs, usage: usage} = completion} ->
        # Update conversation state and log usage and response
        Services.Conversation.replace_msgs(new_msgs, state.conversation_pid)
        tools_used = AI.Agent.tools_used(completion)

        tools_used
        |> Enum.map(fn {tool, count} -> "- #{tool}: #{count} invocation(s)" end)
        |> Enum.join("\n")
        |> then(fn
          "" -> UI.debug("Tools used", "None")
          some -> UI.debug("Tools used", some)
        end)

        editing_tools_used =
          state.editing_tools_used ||
            Map.has_key?(tools_used, "coder_tool") ||
            Map.has_key?(tools_used, "file_edit_tool") ||
            Map.has_key?(tools_used, "apply_patch")

        new_state =
          state
          |> Map.put(:usage, usage)
          |> Map.put(:last_response, response)
          |> Map.put(:editing_tools_used, editing_tools_used)
          |> Map.put(:model, state.model)
          |> log_usage()
          |> log_response()
          |> append_context_remaining()

        # If more interrupts arrived during completion, process them recursively
        if Services.Conversation.Interrupts.pending?(state.conversation_pid) do
          get_completion(new_state, replay)
        else
          new_state
        end

      {:error, %{response: response}} ->
        UI.error("Derp. Completion failed.", response)

        if Services.Conversation.Interrupts.pending?(state.conversation_pid) do
          get_completion(state, replay)
        else
          {:error, response}
        end

      {:error, reason} ->
        UI.error("Derp. Completion failed.", inspect(reason))

        if Services.Conversation.Interrupts.pending?(state.conversation_pid) do
          get_completion(state, replay)
        else
          {:error, reason}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Output
  # ----------------------------------------------------------------------------
  defp log_response(%{steps: []} = state) do
    UI.debug("Response complete")
    state
  end

  defp log_response(%{last_response: thought} = state) do
    thought
    # "reasoning" models often leave the <think> tags in the response
    |> String.replace(~r/<think>(.*)<\/think>/, "\\1")
    |> Util.truncate(25)
    |> UI.italicize()
    |> then(&UI.debug("Considering", &1))

    state
  end

  defp log_usage(%{usage: usage, model: model} = response) do
    UI.log_usage(model, usage)
    response
  end

  # Appends a system message showing the LLM how many context tokens remain
  # before their conversation history will be compacted and returns the state.
  @spec append_context_remaining(t) :: t
  defp append_context_remaining(state) do
    remaining = max(state.context - state.usage, 0)

    AI.Util.system_msg("Context tokens remaining before compaction: #{remaining}")
    |> Services.Conversation.append_msg(state.conversation_pid)

    state
  end
end
