defmodule TaskServer do
  defstruct [
    :next_id,
    :lists
  ]

  @type task :: %{
          id: non_neg_integer | binary,
          outcome: :todo | :done | :failed,
          data: any,
          result: any
        }

  @type list_id :: non_neg_integer
  @type task_id :: binary
  @type task_data :: any
  @type task_result :: any

  @type t :: %__MODULE__{
          next_id: non_neg_integer,
          lists: %{
            list_id => list(task)
          }
        }

  @type stack_operation_result :: :ok | {:error, :not_found | :empty}
  @type peek_result :: {:ok, task} | {:error, :not_found | :empty}
  @type get_list_result :: list(task) | {:error, :not_found}

  use GenServer

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------
  @spec start_link(any) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_list() :: list_id
  def start_list() do
    GenServer.call(__MODULE__, :start_list)
  end

  @spec get_list(list_id) :: get_list_result
  def get_list(list_id) do
    GenServer.call(__MODULE__, {:get_list, list_id})
  end

  @spec add_task(list_id, task_id, task_data) :: :ok
  def add_task(list_id, task_id, task_data) do
    GenServer.cast(__MODULE__, {:add_task, list_id, task_id, task_data})
  end

  @spec complete_task(list_id, task_id, task_result) :: :ok
  def complete_task(list_id, task_id, result) do
    GenServer.cast(__MODULE__, {:complete_task, list_id, task_id, :done, result})
  end

  @spec fail_task(list_id, task_id, task_result) :: :ok
  def fail_task(list_id, task_id, msg) do
    GenServer.cast(__MODULE__, {:complete_task, list_id, task_id, :failed, msg})
  end

  @spec push_task(list_id, task_id, task_data) :: :ok
  def push_task(list_id, task_id, task_data) do
    GenServer.cast(__MODULE__, {:push_task, list_id, task_id, task_data})
  end

  @spec drop_task(list_id) :: :ok
  def drop_task(list_id) do
    GenServer.cast(__MODULE__, {:drop_task, list_id})
  end

  @spec peek_task(list_id) :: peek_result
  def peek_task(list_id) do
    GenServer.call(__MODULE__, {:peek_task, list_id})
  end

  @spec mark_current_done(list_id, task_result) :: :ok
  def mark_current_done(list_id, result) do
    GenServer.cast(__MODULE__, {:mark_current_done, list_id, result})
  end

  @spec mark_current_failed(list_id, task_result) :: :ok
  def mark_current_failed(list_id, msg) do
    GenServer.cast(__MODULE__, {:mark_current_failed, list_id, msg})
  end

  @doc """
  Check if a list exists and is in a valid state.
  """
  @spec list_exists?(list_id) :: boolean
  def list_exists?(list_id) do
    case get_list(list_id) do
      {:error, :not_found} -> false
      _ -> true
    end
  end

  @doc """
  Get health information about a list, including task counts by status.
  """
  @spec list_health(list_id) :: {:ok, map} | {:error, :not_found}
  def list_health(list_id) do
    case get_list(list_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      tasks ->
        counts =
          Enum.reduce(tasks, %{todo: 0, done: 0, failed: 0}, fn task, acc ->
            Map.update!(acc, task.outcome, &(&1 + 1))
          end)

        {:ok,
         %{
           total_tasks: length(tasks),
           task_counts: counts,
           has_todo_tasks: counts.todo > 0,
           has_failed_tasks: counts.failed > 0
         }}
    end
  end

  @doc """
  Validate that all tasks in a list have valid structure and state.
  """
  @spec validate_list_integrity(list_id) :: :ok | {:error, binary}
  def validate_list_integrity(list_id) do
    case get_list(list_id) do
      {:error, :not_found} ->
        {:error, "List #{list_id} does not exist"}

      tasks ->
        invalid_tasks =
          Enum.filter(tasks, fn task ->
            not is_valid_task?(task)
          end)

        case invalid_tasks do
          [] -> :ok
          _ -> {:error, "Found #{length(invalid_tasks)} invalid tasks in list #{list_id}"}
        end
    end
  end

  defp is_valid_task?(%{id: id, outcome: outcome, data: _data, result: _result})
       when is_binary(id) or is_integer(id) do
    outcome in [:todo, :done, :failed]
  end

  defp is_valid_task?(_), do: false

  @spec as_string(non_neg_integer | list(task), boolean) :: binary
  def as_string(subject, detail? \\ false)

  def as_string(list_id, detail?) when is_integer(list_id) do
    list_id
    |> get_list()
    |> case do
      {:error, :not_found} -> "List #{list_id} not found"
      tasks -> as_string(tasks, detail?)
    end
  end

  def as_string([], _), do: ""

  def as_string([task | tasks], detail?) do
    as_string(task, detail?) <> "\n" <> as_string(tasks, detail?)
  end

  def as_string(%{id: id, outcome: :todo}, _), do: "- [ ] #{id}"
  def as_string(%{id: id, outcome: :done}, false), do: "- [✓] #{id}"
  def as_string(%{id: id, outcome: :failed}, false), do: "- [✗] #{id}"

  def as_string(%{id: id, outcome: :done, result: result}, true) do
    "- [✓] #{id}: #{result}"
  end

  def as_string(%{id: id, outcome: :failed, result: result}, true) do
    "- [✗] #{id}: #{result}"
  end

  # ----------------------------------------------------------------------------
  # Server Callbacks
  # ----------------------------------------------------------------------------
  def init(_) do
    {:ok, %__MODULE__{next_id: 1, lists: %{}}}
  end

  def handle_call(:start_list, _from, %{lists: lists, next_id: next_id} = state) do
    {:reply, next_id,
     %{
       state
       | lists: Map.put(lists, next_id, []),
         next_id: next_id + 1
     }}
  end

  def handle_call({:get_list, list_id}, _from, state) do
    state.lists
    |> Map.get(list_id)
    |> case do
      nil ->
        {:reply, {:error, :not_found}, state}

      tasks ->
        tasks
        |> Enum.reverse()
        |> then(&{:reply, &1, state})
    end
  end

  def handle_call({:peek_task, list_id}, _from, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, []} ->
        {:reply, {:error, :empty}, state}

      {:ok, [task | _]} ->
        {:reply, {:ok, task}, state}
    end
  end

  def handle_cast({:add_task, list_id, task_id, task_data}, state) do
    # Silently ignore operations on nonexistent lists
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, tasks} ->
        task = %{
          id: task_id,
          data: task_data,
          outcome: :todo,
          result: nil
        }

        new_list = [task | tasks]
        {:noreply, %{state | lists: Map.put(state.lists, list_id, new_list)}}
    end
  end

  def handle_cast({:complete_task, list_id, task_id, outcome, result}, state) do
    state
    |> Map.get(:lists, %{})
    |> Map.fetch(list_id)
    |> case do
      :error ->
        {:noreply, state}

      {:ok, tasks} ->
        tasks
        |> Enum.map(fn
          %{id: ^task_id} = task -> %{task | outcome: outcome, result: result}
          task -> task
        end)
        |> then(&{:noreply, %{state | lists: Map.put(state.lists, list_id, &1)}})
    end
  end

  def handle_cast({:push_task, list_id, task_id, task_data}, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, tasks} ->
        task = %{
          id: task_id,
          data: task_data,
          outcome: :todo,
          result: nil
        }

        new_list = [task | tasks]
        {:noreply, %{state | lists: Map.put(state.lists, list_id, new_list)}}
    end
  end

  def handle_cast({:drop_task, list_id}, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, []} ->
        {:noreply, state}

      {:ok, [_head | tail]} ->
        {:noreply, %{state | lists: Map.put(state.lists, list_id, tail)}}
    end
  end

  def handle_cast({:mark_current_done, list_id, result}, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, []} ->
        {:noreply, state}

      {:ok, [head | tail]} ->
        updated_head = %{head | outcome: :done, result: result}
        new_list = [updated_head | tail]
        {:noreply, %{state | lists: Map.put(state.lists, list_id, new_list)}}
    end
  end

  def handle_cast({:mark_current_failed, list_id, msg}, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, []} ->
        {:noreply, state}

      {:ok, [head | tail]} ->
        updated_head = %{head | outcome: :failed, result: msg}
        new_list = [updated_head | tail]
        {:noreply, %{state | lists: Map.put(state.lists, list_id, new_list)}}
    end
  end
end
