defmodule AI.Agent.Coordinator.Tasks do
  @moduledoc """
  Task-specific behaviors for AI.Agent.Coordinator, including generating
  messages related to task management.
  """

  @typep t :: AI.Agent.Coordinator.t()

  @doc """
  Return a list of task list IDs that have incomplete tasks. This function
  filters the task lists associated with the conversation to identify those
  that are still in progress and contain at least one task with an outcome of
  `:todo`.
  """
  @spec pending_lists(t) :: list
  def pending_lists(state) do
    Services.Task.list_ids()
    |> Enum.filter(fn list_id ->
      state.conversation_pid
      |> Services.Conversation.get_task_list_meta(list_id)
      |> case do
        {:ok, %{} = m} -> Map.get(m, :status)
        _ -> nil
      end
      |> case do
        "in-progress" ->
          false

        _ ->
          list_id
          |> Services.Task.get_list()
          |> case do
            {:error, _} -> false
            tasks -> Enum.any?(tasks, fn t -> t.outcome == :todo end)
          end
      end
    end)
  end

  @doc """
  Appends a message to the conversation, instructing the agent to use a task
  list for managing research. It emphasizes creating tasks for new lines of
  inquiry, resolving tasks with clear outcomes, and reviewing the task list
  before proceeding to the next steps.
  """
  @spec research_msg(t) :: t
  def research_msg(%{conversation_pid: conversation_pid} = state) do
    """
    Use your task list to manage all research:
    - For every new line of inquiry, create a task
    - When you conclude or drop a line, resolve it with a clear outcome
    - Before moving to the next, call `tasks_show_list` to review and update open tasks
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @doc """
  Appends a message to the conversation, reminding the agent to check their
  task lists for any incomplete tasks. It provides guidelines on how to manage
  tasks, including resolving completed tasks, addressing stale or irrelevant
  tasks, and ensuring that all tasks are concrete and actionable. The message
  also includes a list of task IDs that still have incomplete tasks.
  """
  @spec penultimate_check_msg(t, list) :: t
  def penultimate_check_msg(%{conversation_pid: conversation_pid} = state, list_ids) do
    md_list =
      list_ids
      |> Enum.map(&" - ID: `#{&1}`")
      |> Enum.join("\n")

    """
    # Task lists check-in
    Task lists are persisted with the conversation.

    It is OK to leave tasks open across multiple sessions when they represent real follow-up work.
    - Use `tasks_show_list` and read it carefully.
    - If a task is done, resolve it.
    - If a task should not persist (stale, superseded, or no longer relevant), resolve it with a short note explaining why.
    - If a task is vague, rewrite it into a concrete follow-up (label + detailed description + rationale).

    The following task lists still have incomplete tasks:
    #{md_list}
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @doc """
  Appends a message to the conversation, providing an overview of the current
  task lists. It lists the IDs of all task lists and instructs the agent to use
  the `tasks_show_list` tool to view the tasks in more detail, including their
  descriptions and statuses.
  """
  @spec list_msg(t) :: t
  def list_msg(%{conversation_pid: conversation_pid} = state) do
    tasks =
      Services.Task.list_ids()
      |> Enum.map(fn list_id ->
        tasks = Services.Task.as_string(list_id)

        """
        ## Task list ID: `#{list_id}`
        Use this ID when invoking task management tools for this list.
        #{tasks}
        """
      end)
      |> Enum.join("\n\n")

    """
    # Tasks
    The `tasks_show_list` tool displays these tasks in more detail, including descriptions and statuses.
    #{tasks}
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec log_summary(t) :: map
  def log_summary(%{conversation_pid: convo} = state) do
    convo
    # task_summary produces markdown text. Allow an external FNORD_FORMATTER to
    # transform the markdown into nicer terminal output if configured.
    |> task_summary()
    # Remove leading "# Tasks\n" header; that was originally intended for the
    # LLM-facing message. Here, it's redundant, since we're using the "Tasks"
    # label in our call to UI.debug.
    |> String.replace_prefix("# Tasks\n", "")
    # UI.Formatter.format_output will run the command configured by
    # FNORD_FORMATTER and return a binary. It also respects UI.quiet?().
    |> UI.Formatter.format_output()
    # UI.debug accepts both chardata and iodata; pass formatted text directly.
    |> then(&UI.debug("Task lists", &1))

    state
  end

  @doc """
  Return a formatted Coordinator-scoped task summary for the given conversation
  PID.
  """
  @spec task_summary(pid()) :: binary()
  def task_summary(conversation_pid) when is_pid(conversation_pid) do
    conversation_pid
    |> Services.Conversation.get_task_lists()
    |> Enum.map(&format_task_list(conversation_pid, &1))
    |> Enum.join("\n\n")
    |> then(fn body ->
      """
      # Tasks

      #{body}
      """
    end)
  end

  @doc """
  Return a formatted summary of a single task list, including its description,
  status, and the status of each individual task. The summary derives the list
  status from the current tasks when possible, reflecting the concrete state of
  work.
  """
  @spec format_task_list(pid, binary) :: binary
  def format_task_list(conversation_pid, list_id) do
    with tasks = Services.Conversation.get_task_list(conversation_pid, list_id),
         {:ok, meta} <- Services.Conversation.get_task_list_meta(conversation_pid, list_id),
         {:ok, desc} <- Map.fetch(meta, :description),
         {:ok, status} <- Map.fetch(meta, :status) do
      name = desc || list_id

      label =
        case status do
          "done" -> "Complete"
          "in-progress" -> "In Progress"
          _ -> "Planning"
        end

      "## #{name} :: #{label}" <> format_tasks(status, tasks)
    end
  end

  defp format_tasks(_, []), do: ""
  defp format_tasks("done", _), do: ""

  defp format_tasks(_, tasks) do
    tasks
    |> Enum.map(&format_task/1)
    |> Enum.join("\n")
    |> then(&("\n" <> &1))
  end

  defp format_task(%{id: id, outcome: outcome, result: result}) do
    tty? = UI.colorize?()

    result =
      if result do
        IO.ANSI.format([": ", :italic, :light_black, result, :reset], tty?)
      else
        ""
      end

    format_task_for_ui(id, outcome, result, tty?)
  end

  defp format_task_for_ui(id, :done, result, false), do: "- [✓] #{id}#{result}"
  defp format_task_for_ui(id, :done, result, true), do: done("- #{id}#{result}")
  defp format_task_for_ui(id, :failed, result, false), do: "- [✗] #{id}#{result}"
  defp format_task_for_ui(id, :failed, result, true), do: failed("- #{id}#{result}")
  defp format_task_for_ui(id, :todo, _, false), do: "- [ ] #{id}"
  defp format_task_for_ui(id, :todo, _, true), do: todo("- #{id}")

  defp done(v), do: IO.ANSI.format([:green, v, :reset], true)
  defp failed(v), do: IO.ANSI.format([:red, :crossed_out, v, :reset], true)
  defp todo(v), do: IO.ANSI.format([:cyan, v, :reset], true)
end
