defmodule TaskServer do
  use GenServer

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------

  @doc """
  Starts the TaskServer.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, any()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new task list and returns its ID.
  """
  @spec start_list() :: integer()
  def start_list() do
    GenServer.call(__MODULE__, :start_list)
  end

  @doc """
  Adds a task with the given name to the list with the given ID.
  """
  @spec add_task(integer(), String.t()) :: :ok
  def add_task(list_id, task_name) do
    GenServer.cast(__MODULE__, {:add_task, list_id, task_name})
  end

  @doc "Pushes task_name to the top of the task list for the given list_id."
  @spec push_task(integer(), String.t()) :: :ok
  def push_task(list_id, task_name) do
    GenServer.cast(__MODULE__, {:push_task, list_id, task_name})
  end

  @doc """
  Marks the specified task in the list with the given ID as complete with the given outcome.
  The task may be specified by its zero-based index (integer) or by its name (string).
  Using an index updates the outcome of the task at that position; using a name updates the outcome of the matching task(s).
  """
  @spec complete_task(integer(), integer() | String.t(), atom() | String.t()) :: :ok
  def complete_task(list_id, task_name, outcome) do
    GenServer.cast(__MODULE__, {:complete_task, list_id, task_name, outcome})
  end

  @doc """
  Retrieves the list of tasks for the given list ID.
  """
  @spec get_list(integer()) :: [%{name: String.t(), outcome: atom() | String.t()}]
  def get_list(list_id) do
    GenServer.call(__MODULE__, {:get_list, list_id})
  end

  # ----------------------------------------------------------------------------
  # Server Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, %{next_id: 1, lists: %{}}}
  end

  @impl true
  def handle_call(:start_list, _from, state) do
    id = state.next_id
    lists = Map.put(state.lists, id, [])
    new_state = %{state | next_id: id + 1, lists: lists}
    {:reply, id, new_state}
  end

  @impl true
  def handle_call({:get_list, list_id}, _from, state) do
    tasks = Map.get(state.lists, list_id, [])
    {:reply, tasks, state}
  end

  @impl true
  def handle_cast({:add_task, list_id, task_name}, state) do
    if Map.has_key?(state.lists, list_id) do
      tasks = Map.get(state.lists, list_id)
      new_task = %{name: task_name, outcome: :todo}
      lists = Map.put(state.lists, list_id, tasks ++ [new_task])
      {:noreply, %{state | lists: lists}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:push_task, list_id, task_name}, state) do
    if Map.has_key?(state.lists, list_id) do
      tasks = Map.get(state.lists, list_id)
      new_task = %{name: task_name, outcome: :todo}
      lists = Map.put(state.lists, list_id, [new_task | tasks])
      {:noreply, %{state | lists: lists}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:complete_task, list_id, task_id, outcome}, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, tasks} ->
        cond do
          is_integer(task_id) ->
            if task_id >= 0 and task_id < length(tasks) do
              updated_tasks =
                List.update_at(tasks, task_id, fn task -> Map.put(task, :outcome, outcome) end)

              lists = Map.put(state.lists, list_id, updated_tasks)
              {:noreply, %{state | lists: lists}}
            else
              {:noreply, state}
            end

          is_binary(task_id) ->
            updated_tasks =
              Enum.map(tasks, fn
                %{name: ^task_id} = task -> Map.put(task, :outcome, outcome)
                other -> other
              end)

            if updated_tasks == tasks do
              {:noreply, state}
            else
              lists = Map.put(state.lists, list_id, updated_tasks)
              {:noreply, %{state | lists: lists}}
            end

          true ->
            {:noreply, state}
        end
    end
  end
end
