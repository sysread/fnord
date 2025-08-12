defmodule Services.Task do
  defstruct [
    :next_id,
    :lists
  ]

  @type list_id :: non_neg_integer
  @type task_id :: binary
  @type task_data :: any
  @type task_result :: any
  @type task :: %{
          id: task_id,
          outcome: :todo | :done | :failed,
          data: task_data,
          result: task_result | nil
        }

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

  @spec get_list(list_id) :: [task] | {:error, :not_found}
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

  @spec peek_task(list_id) :: {:ok, task} | {:error, :not_found} | {:error, :empty}
  def peek_task(list_id) do
    GenServer.call(__MODULE__, {:peek_task, list_id})
  end

  @spec as_string(list_id | list(task), boolean) :: binary
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

  def as_string(%{id: id, outcome: :todo}, _), do: "[ ] #{id}"
  def as_string(%{id: id, outcome: :done}, _), do: "[✓] #{id}"
  def as_string(%{id: id, outcome: :failed}, _), do: "[✗] #{id}"

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

      {:ok, tasks} ->
        tasks
        |> Enum.reverse()
        |> Enum.find(fn task -> task.outcome == :todo end)
        |> case do
          nil -> {:reply, {:error, :empty}, state}
          task -> {:reply, {:ok, task}, state}
        end
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
        |> then(&{:noreply, %{state | lists: %{state.lists | list_id => &1}}})
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

        new_list = tasks ++ [task]
        {:noreply, %{state | lists: %{state.lists | list_id => new_list}}}
    end
  end

  def handle_cast({:drop_task, list_id}, state) do
    state.lists
    |> Map.fetch(list_id)
    |> case do
      :error -> {:noreply, state}
      {:ok, []} -> {:noreply, state}
      {:ok, [_head | tail]} -> {:noreply, %{state | lists: %{state.lists | list_id => tail}}}
    end
  end
end