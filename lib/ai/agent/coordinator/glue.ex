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
    |> AI.Tools.with_mcps()
    |> AI.Tools.with_frobs()
    |> AI.Tools.with_task_tools()
    |> AI.Tools.with_skills()
    |> AI.Tools.with_rw_tools()
    |> maybe_with_worktree_tool()
    |> AI.Tools.with_coding_tools()
    |> AI.Tools.with_review_tools()
    |> AI.Tools.with_web_tools()
    |> AI.Tools.maybe_with_ui()
  end

  def get_tools(_) do
    AI.Tools.basic_tools()
    |> AI.Tools.with_mcps()
    |> AI.Tools.with_frobs()
    |> AI.Tools.with_task_tools()
    |> AI.Tools.with_skills()
    |> AI.Tools.with_review_tools()
    |> AI.Tools.with_web_tools()
    |> AI.Tools.maybe_with_ui()
  end

  defp maybe_with_worktree_tool(toolbox) do
    if GitCli.is_git_repo?() do
      AI.Tools.with_worktree_tool(toolbox, true)
    else
      toolbox
    end
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

    # Invoke completion once, ensuring conversation state is included.
    # `verbosity` is forwarded explicitly: AI.Completion.new/1 reads it as
    # a standalone opt (not from model.verbosity), so the -V/--frippery
    # user flag would otherwise be a no-op on the Coordinator path.
    AI.Agent.get_completion(state.agent,
      log_msgs: true,
      log_tool_calls: true,
      archive_notes: true,
      compact?: true,
      replay_conversation: replay,
      conversation_pid: state.conversation_pid,
      model: state.model,
      verbosity: state.model.verbosity,
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
          state.editing_tools_used || code_modifying_tools_used?(tools_used)

        new_state =
          state
          |> Map.put(:usage, usage)
          |> Map.put(:last_response, response)
          |> Map.put(:editing_tools_used, editing_tools_used)
          |> Map.put(:model, state.model)
          |> maybe_run_validation(tools_used)
          |> maybe_nudge_worktree_commit(tools_used)
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

  # Deduplication is keyed only on the changed-file fingerprint, not on rule
  # configuration or command outcomes. If the dirty file set is unchanged but
  # rules were edited externally (e.g. via settings.json), the report for the
  # new rule set will be suppressed until the file set changes. In practice
  # this is a narrow window since rules are managed via CLI in a separate
  # process, not mid-conversation.
  defp maybe_run_validation(state, tools_used) do
    if code_modifying_tools_used?(tools_used) do
      Validation.Rules.debug("Running validation after code-modifying tools")
      result = Validation.Rules.run()

      case result do
        {:ok, :no_changes} ->
          Validation.Rules.debug("Validation returned no fingerprint: no changes")
          state

        {:error, :discovery_failed} ->
          Validation.Rules.debug("Changed file discovery failed")
          report_validation_result(state, result)

        _ ->
          fingerprint = validation_fingerprint(result)

          if fingerprint == state.last_validation_fingerprint do
            Validation.Rules.debug("Validation fingerprint unchanged: skipping report")
            state
          else
            Validation.Rules.debug("Validation fingerprint changed: reporting result")
            report_validation_result(state, result)
          end
      end
    else
      state
    end
  end

  # After validation, remind the coordinator to commit if working in a
  # fnord-managed worktree with uncommitted changes. Appended to the
  # conversation so the LLM sees it alongside validation results and can act
  # in the same turn.
  defp maybe_nudge_worktree_commit(state, tools_used) do
    if code_modifying_tools_used?(tools_used) and worktree_has_uncommitted_changes?() do
      """
      You have uncommitted changes in the active worktree. Use `git_worktree_tool`
      with action `commit` to commit them. If stopping due to blockers, set `wip`
      to `true` and describe the problems in the message.
      """
      |> AI.Util.system_msg()
      |> Services.Conversation.append_msg(state.conversation_pid)

      state
    else
      state
    end
  end

  defp worktree_has_uncommitted_changes? do
    case Settings.get_project_root_override() do
      nil ->
        false

      path ->
        with {:ok, project} <- Store.get_project(),
             true <- GitCli.Worktree.fnord_managed?(project.name, path) do
          GitCli.Worktree.has_uncommitted_changes?(path)
        else
          _ -> false
        end
    end
  end

  # These are the tools that produce source code changes in the project tree.
  # cmd_tool is excluded because it primarily runs read-only commands (git log,
  # grep, etc.) and any file mutations it causes will be picked up on the next
  # edit-tool turn when the fingerprint changes. save_skill writes to ~/.fnord/,
  # not project source files.
  defp code_modifying_tools_used?(tools_used) do
    Enum.any?(tools_used, fn
      {tool, count} when count > 0 -> tool in ["coder_tool", "file_edit_tool", "apply_patch"]
      _ -> false
    end)
  end

  defp validation_fingerprint({:ok, :no_rules, _, fingerprint}), do: fingerprint
  defp validation_fingerprint({:ok, :no_matches, _, fingerprint}), do: fingerprint
  defp validation_fingerprint({:ok, _results, fingerprint}), do: fingerprint
  defp validation_fingerprint({:error, _result, fingerprint}), do: fingerprint

  defp report_validation_result(state, {:error, :discovery_failed} = result) do
    summary = Validation.Rules.summarize(result)
    UI.error("Validation", "Could not determine changed files (git status failed)")

    AI.Util.system_msg(summary)
    |> Services.Conversation.append_msg(state.conversation_pid)

    state
  end

  defp report_validation_result(state, result) do
    summary = Validation.Rules.summarize(result)

    case validation_ui_detail(result) do
      {:info, detail} -> UI.info("Validation", detail)
      {:error, detail} -> UI.error("Validation", detail)
    end

    AI.Util.system_msg(summary)
    |> Services.Conversation.append_msg(state.conversation_pid)

    Map.put(state, :last_validation_fingerprint, validation_fingerprint(result))
  end

  defp validation_ui_detail({:ok, :no_rules, _, _}), do: {:info, "No rules found"}
  defp validation_ui_detail({:ok, :no_matches, _, _}), do: {:info, "No matching rules"}

  defp validation_ui_detail({:ok, results, _}) when is_list(results),
    do: {:info, "#{length(results)} commands succeeded"}

  defp validation_ui_detail({:error, reason, _}), do: {:error, "Run failed: #{inspect(reason)}"}
end
