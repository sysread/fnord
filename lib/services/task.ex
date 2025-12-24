defmodule Services.Task do
  defstruct [
    :conversation_pid,
    :next_id,
    :lists
  ]

  @type list_id :: non_neg_integer
  @type task_id :: binary
  @type task_data :: any
  @type task_result :: any
  @type task_list :: list(task)

  @type task :: %{
          id: task_id,
          outcome: :todo | :done | :failed,
          data: task_data,
          result: task_result | nil
        }

  use GenServer

  @doc """
  Creates a new task with the given ID and data. Optionally accepts `:outcome`
  (default `:todo`) and `:result` (default `nil`).
  """
  @spec new_task(task_id, task_data, keyword) :: task
  def new_task(task_id, data, opts \\ []) do
    outcome = Keyword.get(opts, :outcome, :todo)
    result = Keyword.get(opts, :result, nil)

    %{
      id: task_id,
      data: data,
      outcome: outcome,
      result: result
    }
  end

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------
  @spec start_link(any) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with {:ok, _conversation_pid} <- Keyword.fetch(opts, :conversation_pid) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :error -> {:error, :missing_conversation_pid}
    end
  end

  @spec start_list() :: list_id
  def start_list() do
    GenServer.call(__MODULE__, :start_list)
  end

  @doc """
  Returns all active task list IDs.
  """
  @spec list_ids() :: [list_id]
  def list_ids() do
    GenServer.call(__MODULE__, :list_ids)
  end

  @doc """
  Fetches all tasks for the given list in chronological (oldest-first) order.
  Returns `{:error, :not_found}` if the list does not exist.
  """
  @spec get_list(list_id) :: task_list | {:error, :not_found}
  def get_list(list_id) do
    GenServer.call(__MODULE__, {:get_list, list_id})
  end

  @doc """
  Appends a new :todo task with the given ID and data to the end of the list.
  If the list does not exist or the task ID already exists, this call is ignored.
  """
  @spec add_task(list_id, task_id, task_data) :: :ok
  def add_task(list_id, task_id, task_data) do
    GenServer.cast(__MODULE__, {:add_task, list_id, task_id, task_data})
  end

  @doc """
  Inserts a new :todo task with the given ID and data to the front of the list.
  If the list does not exist or the task ID already exists, this call is ignored.
  """
  @spec push_task(list_id, task_id, task_data) :: :ok
  def push_task(list_id, task_id, task_data) do
    GenServer.cast(__MODULE__, {:push_task, list_id, task_id, task_data})
  end

  @doc """
  Marks the first task matching `task_id` as :done and stores the result.
  Only the first matching ID is updated; others are unchanged.
  No-op if list or task not found.
  """
  @spec complete_task(list_id, task_id, task_result) :: :ok
  def complete_task(list_id, task_id, result) do
    GenServer.cast(__MODULE__, {:resolve, list_id, task_id, :done, result})
  end

  @doc """
  Marks the first task matching `task_id` as :failed and stores the result.
  Only the first matching ID is updated; others are unchanged.
  No-op if list or task not found.
  """
  @spec fail_task(list_id, task_id, task_result) :: :ok
  def fail_task(list_id, task_id, msg) do
    GenServer.cast(__MODULE__, {:resolve, list_id, task_id, :failed, msg})
  end

  @doc """
  Returns `{:ok, task}` for the first :todo task in chronological order.
  Returns `{:error, :empty}` if no pending tasks, or `{:error, :not_found}` if the list does not exist.
  """
  @spec peek_task(list_id) :: {:ok, task} | {:error, :not_found} | {:error, :empty}
  def peek_task(list_id) do
    GenServer.call(__MODULE__, {:peek_task, list_id})
  end

  @doc """
  Returns `true` if there are no remaining `:todo`s in the list.
  """
  @spec all_tasks_complete?(list_id) :: {:ok, boolean}
  def all_tasks_complete?(list_id) do
    case get_list(list_id) do
      {:error, :not_found} -> {:error, :not_found}
      tasks -> {:ok, Enum.all?(tasks, &(&1.outcome != :todo))}
    end
  end

  # ----------------------------------------------------------------------------
  # Formatting
  # ----------------------------------------------------------------------------
  @spec as_string(list_id | list(task), boolean) :: binary
  def as_string(subject, detail? \\ false)

  def as_string(list_id, detail?) when is_integer(list_id) do
    list_id
    |> get_list()
    |> case do
      {:error, :not_found} ->
        "List #{list_id} not found"

      tasks ->
        contents =
          tasks
          |> as_string(detail?)
          |> String.trim()

        """
        Task List #{list_id}:
        #{contents}
        """
    end
  end

  def as_string([], _), do: ""

  def as_string([task | remaining], detail?) do
    [
      as_string(task, detail?),
      as_string(remaining, detail?)
    ]
    |> Enum.join("\n")
  end

  def as_string(%{id: id, outcome: :done, result: result}, true) do
    "[✓] #{id}: #{result}"
  end

  def as_string(%{id: id, outcome: :failed, result: result}, true) do
    "[✗] #{id}: #{result}"
  end

  def as_string(%{id: id, outcome: :todo}, _), do: "[ ] #{Util.truncate_chars(id, 16)}"
  def as_string(%{id: id, outcome: :done}, _), do: "[✓] #{Util.truncate_chars(id, 16)}"
  def as_string(%{id: id, outcome: :failed}, _), do: "[✗] #{Util.truncate_chars(id, 16)}"

  # ----------------------------------------------------------------------------
  # Server Callbacks
  # ----------------------------------------------------------------------------
  @impl true
  def init(opts) do
    conversation_pid = Keyword.fetch!(opts, :conversation_pid)
    tasks = rehydrate_tasks(conversation_pid)
    max_id = [0 | Map.keys(tasks)] |> Enum.max()

    {:ok,
     %__MODULE__{
       conversation_pid: conversation_pid,
       next_id: max_id + 1,
       lists: tasks
     }}
  end

  @impl true
  def handle_call(:start_list, _from, %{lists: lists, next_id: next_id} = state) do
    {:reply, next_id,
     %{
       state
       | lists: Map.put(lists, next_id, []),
         next_id: next_id + 1
     }}
  end

  @impl true
  def handle_call(:list_ids, _from, state) do
    {:reply, Map.keys(state.lists), state}
  end

  @impl true
  def handle_call({:get_list, list_id}, _from, state) do
    state.lists
    |> Map.get(list_id)
    |> case do
      nil ->
        {:reply, {:error, :not_found}, state}

      tasks ->
        {:reply, tasks, state}
    end
  end

  @impl true
  def handle_call({:peek_task, list_id}, _from, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, tasks} ->
        Enum.find(tasks, fn task -> task.outcome == :todo end)
        |> case do
          nil -> {:reply, {:error, :empty}, state}
          task -> {:reply, {:ok, task}, state}
        end
    end
  end

  @impl true
  def handle_cast({:push_task, list_id, task_id, task_data}, state) do
    # Silently ignore operations on nonexistent lists
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, tasks} ->
        if Enum.any?(tasks, &(&1.id == task_id)) do
          {:noreply, state}
        else
          task = new_task(task_id, task_data)
          # Prepend new task to the front of the list
          %{state | lists: Map.put(state.lists, list_id, [task | tasks])}
          |> save_tasks()
          |> then(&{:noreply, &1})
        end
    end
  end

  @impl true
  def handle_cast({:add_task, list_id, task_id, task_data}, state) do
    # Silently ignore operations on nonexistent lists
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, tasks} ->
        if Enum.any?(tasks, &(&1.id == task_id)) do
          {:noreply, state}
        else
          task = new_task(task_id, task_data)
          # Append new task to preserve insertion order
          %{state | lists: Map.put(state.lists, list_id, tasks ++ [task])}
          |> save_tasks()
          |> then(&{:noreply, &1})
        end
    end
  end

  @impl true
  def handle_cast({:resolve, list_id, task_id, outcome, result}, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, tasks} ->
        with {updated_tasks, _} <- resolve_task(tasks, task_id, outcome, result) do
          %{state | lists: Map.put(state.lists, list_id, updated_tasks)}
          |> save_tasks()
          |> then(&{:noreply, &1})
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec resolve_task([task()], task_id(), :done | :failed, task_result()) :: {[task()], boolean()}
  defp resolve_task(tasks, target_id, outcome, result) do
    # Split the list into tasks before the match and the rest
    {before, rest} = Enum.split_while(tasks, &(&1.id != target_id))

    case rest do
      [] ->
        # No matching task: return original list and a flag indicating no change
        {tasks, false}

      [first | tail] ->
        # Update only the first matching task's outcome and result
        updated = %{first | outcome: outcome, result: result}
        {before ++ [updated | tail], true}
    end
  end

  defp save_tasks(%{conversation_pid: pid} = state) do
    state.lists
    |> Enum.map(fn {list_id, tasks} ->
      Services.Conversation.upsert_task_list(pid, list_id, tasks)
    end)

    state
  end

  defp rehydrate_tasks(pid) do
    pid
    |> Services.Conversation.get_task_lists()
    |> Enum.map(fn task_list_id ->
      case Services.Conversation.get_task_list(pid, task_list_id) do
        nil ->
          {task_list_id, []}

        tasks ->
          tasks
          |> Enum.map(fn task ->
            %{task | outcome: String.to_existing_atom(task.outcome)}
          end)
          |> then(&{task_list_id, &1})
      end
    end)
    |> Map.new()
  end
end
