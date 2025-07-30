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

  @type t :: %__MODULE__{
          next_id: non_neg_integer,
          lists: %{
            non_neg_integer => list(task)
          }
        }

  use GenServer

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------
  @spec start_link(any) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_list() :: non_neg_integer
  def start_list() do
    GenServer.call(__MODULE__, :start_list)
  end

  @spec get_list(non_neg_integer) :: list(task) | {:error, :not_found}
  def get_list(list_id) do
    GenServer.call(__MODULE__, {:get_list, list_id})
  end

  @spec add_task(non_neg_integer, binary, any) :: :ok
  def add_task(list_id, task_id, task_data) do
    GenServer.cast(__MODULE__, {:add_task, list_id, task_id, task_data})
  end

  @spec complete_task(non_neg_integer, binary, any) :: :ok
  def complete_task(list_id, task_id, result) do
    GenServer.cast(__MODULE__, {:complete_task, list_id, task_id, :done, result})
  end

  @spec fail_task(non_neg_integer, binary, any) :: :ok
  def fail_task(list_id, task_id, msg) do
    GenServer.cast(__MODULE__, {:complete_task, list_id, task_id, :failed, msg})
  end

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

  def handle_cast({:add_task, list_id, task_id, task_data}, state) do
    task = %{
      id: task_id,
      data: task_data,
      outcome: :todo,
      result: nil
    }

    new_list =
      state
      |> Map.get(:lists, %{})
      |> Map.get(list_id, [])
      |> then(&[task | &1])

    {:noreply, %{state | lists: Map.put(state.lists, list_id, new_list)}}
  end

  def handle_cast({:complete_task, list_id, task_id, outcome, result}, state) do
    state
    |> Map.get(:lists, %{})
    |> Map.get(list_id, [])
    |> Enum.map(fn
      %{id: ^task_id} = task ->
        %{task | outcome: outcome, result: result}

      task ->
        task
    end)
    |> then(&{:noreply, %{state | lists: Map.put(state.lists, list_id, &1)}})
  end
end
