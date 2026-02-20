defmodule AI.Agent.Coordinator.Tasks do
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

  @doc """
  Return a formatted summary of a single task list, including its description,
  status, and the status of each individual task. The summary derives the list
  status from the current tasks when possible, reflecting the concrete state of
  work.
  """
  @spec format_task_list(pid, binary) :: binary
  def format_task_list(conversation_pid, list_id) do
    meta =
      case Services.Conversation.get_task_list_meta(conversation_pid, list_id) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    description =
      cond do
        Map.has_key?(meta, :description) -> Map.get(meta, :description)
        Map.has_key?(meta, "description") -> Map.get(meta, "description")
        true -> nil
      end

    status_val =
      cond do
        Map.has_key?(meta, :status) -> Map.get(meta, :status)
        Map.has_key?(meta, "status") -> Map.get(meta, "status")
        true -> nil
      end

    status =
      if status_val in [nil, ""] do
        "planning"
      else
        status_val
      end

    name =
      if description in [nil, ""] do
        "Task List #{list_id}"
      else
        description
      end

    # Derive list status from current tasks when possible so the summary reflects
    # the concrete state of work (mirrors Services.Task transitions):
    # - When all tasks are terminal (not :todo) and list is non-empty => done
    # - When any task is terminal but some remain todo => in-progress
    # - Otherwise, default to the explicit meta.status (or planning)
    tasks = Services.Conversation.get_task_list(conversation_pid, list_id) || []

    all_terminal = Enum.all?(tasks, fn t -> t.outcome != :todo end)

    list_status =
      cond do
        all_terminal and tasks != [] ->
          "[✓] completed"

        Enum.any?(tasks, fn t -> t.outcome != :todo end) ->
          "[ ] in progress"

        true ->
          case status do
            "done" -> "[✓] completed"
            "in-progress" -> "[ ] in progress"
            "planning" -> "[ ] planning"
            other -> "[ ] #{other}"
          end
      end

    task_lines =
      tasks
      |> Enum.map(fn t ->
        outcome = Map.get(t, :outcome)

        status_text =
          case outcome do
            :done -> "[✓] done"
            :failed -> "[✗] failed"
            :todo -> "[ ] todo"
            other -> "[ ] #{inspect(other)}"
          end

        result = Map.get(t, :result)
        result_part = if result in [nil, ""], do: "", else: " (#{result})"

        "  - #{t.id}: #{status_text}#{result_part}"
      end)
      |> Enum.join("\n")

    list_header = "- #{name}: #{list_status}"

    if all_terminal || task_lines == "" do
      list_header
    else
      list_header <> "\n" <> task_lines
    end
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
    |> then(&UI.debug("Tasks", &1))

    state
  end

  @doc """
  Return a formatted Coordinator-scoped task summary for the given conversation
  PID.
  """
  @spec task_summary(pid()) :: binary()
  def task_summary(conversation_pid) when is_pid(conversation_pid) do
    lists = Services.Conversation.get_task_lists(conversation_pid)

    body =
      lists
      |> Enum.map(&format_task_list(conversation_pid, &1))
      |> Enum.join("\n\n")

    "# Tasks\n" <> body
  end
end
