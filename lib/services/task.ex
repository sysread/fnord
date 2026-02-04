defmodule Services.Task do
  defstruct [
    :conversation_pid,
    :lists
  ]

  @type list_id :: binary
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
  Create a new task list with an optional slug id and description.
  If no id is provided, a unique slug of the form "tasks-<n>" is generated.
  If the id already exists, returns {:error, :exists}.
  """
  @spec start_list(%{optional(:id) => binary, optional(:description) => binary} | binary) ::
          list_id | {:error, :exists}
  def start_list(%{id: id} = opts) when is_binary(id) do
    desc = Map.get(opts, :description)
    GenServer.call(__MODULE__, {:start_list, id, desc})
  end

  def start_list(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:start_list, id, nil})
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
  Fetches tasks and description for the given list in a single call.
  Returns `{:ok, tasks, description}` or `{:error, :not_found}`.
  """
  @spec get_list_with_description(list_id) ::
          {:ok, task_list, binary | nil} | {:error, :not_found}
  def get_list_with_description(list_id) when is_binary(list_id) do
    GenServer.call(__MODULE__, {:get_list_with_meta, list_id})
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
    GenServer.call(__MODULE__, {:resolve, list_id, task_id, :done, result})
  end

  @doc """
  Marks the first task matching `task_id` as :failed and stores the result.
  Only the first matching ID is updated; others are unchanged.
  No-op if list or task not found.
  """
  @spec fail_task(list_id, task_id, task_result) :: :ok
  def fail_task(list_id, task_id, msg) do
    GenServer.call(__MODULE__, {:resolve, list_id, task_id, :failed, msg})
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

  @doc """
  Updates the description of the specified task list.
  Returns `:ok` or `{:error, :not_found}` if the list does not exist.
  """
  @spec set_description(list_id, binary) :: :ok | {:error, :not_found}
  def set_description(list_id, description) when is_binary(list_id) and is_binary(description) do
    GenServer.call(__MODULE__, {:set_description, list_id, description})
  end

  @doc """
  Fetches the description of the specified task list. Returns `{:ok, description}` or `{:error, :not_found}`.
  """
  @spec get_description(list_id) :: {:ok, binary | nil} | {:error, :not_found}
  def get_description(list_id) when is_binary(list_id) do
    GenServer.call(__MODULE__, {:get_description, list_id})
  end

  # ----------------------------------------------------------------------------
  # Formatting
  # ----------------------------------------------------------------------------
  @spec as_string(list_id | list(task), boolean) :: binary
  def as_string(subject, detail? \\ false)

  def as_string(list_id, detail?) when is_binary(list_id) do
    # Fetch tasks and description in a single call to avoid race conditions
    case get_list_with_description(list_id) do
      {:error, :not_found} ->
        "List #{list_id} not found"

      {:ok, tasks, description} ->
        # Build header including description when present
        header =
          if description do
            "Task List #{list_id}: #{description}"
          else
            "Task List #{list_id}:"
          end

        contents =
          tasks
          |> as_string(detail?)
          |> String.trim()

        # Render final output
        """
        #{header}
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

  def as_string(%{id: id, outcome: :todo}, _), do: "[ ] #{Util.truncate_chars(id, 100)}"
  def as_string(%{id: id, outcome: :done}, _), do: "[✓] #{Util.truncate_chars(id, 100)}"
  def as_string(%{id: id, outcome: :failed}, _), do: "[✗] #{Util.truncate_chars(id, 100)}"

  # ----------------------------------------------------------------------------
  # Server Callbacks
  # ----------------------------------------------------------------------------
  @impl true
  def init(opts) do
    # Fetch and wrap existing raw tasks into Task.List structs
    conversation_pid = Keyword.fetch!(opts, :conversation_pid)
    raw_tasks_map = rehydrate_tasks(conversation_pid)

    tasklists =
      raw_tasks_map
      |> Enum.map(fn {list_id, tasks} ->
        # get_task_list_meta returns {:ok, desc} | {:error, :not_found}, need to unwrap
        desc =
          case Services.Conversation.get_task_list_meta(conversation_pid, list_id) do
            {:ok, d} -> d
            _ -> nil
          end

        {list_id, %Services.Task.List{id: list_id, description: desc, tasks: tasks}}
      end)
      |> Map.new()

    {:ok,
     %__MODULE__{
       conversation_pid: conversation_pid,
       lists: tasklists
     }}
  end

  @impl true
  def handle_call(:start_list, _from, %{lists: lists} = state) do
    # Generate next slug "tasks-<n>" based on existing ids
    next_number =
      lists
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "tasks-"))
      |> Enum.map(fn id ->
        case String.split(id, "-") do
          ["tasks", n] ->
            case Integer.parse(n) do
              {num, ""} -> num
              _ -> 0
            end

          _ ->
            0
        end
      end)
      |> Enum.max(fn -> 0 end)

    id = "tasks-#{next_number + 1}"
    new_list = %Services.Task.List{id: id, description: nil, tasks: []}

    new_state =
      %{state | lists: Map.put(lists, id, new_list)}
      |> save_tasks()

    {:reply, id, new_state}
  end

  @impl true
  def handle_call({:start_list, id, desc}, _from, %{lists: lists} = state) do
    if Map.has_key?(lists, id) do
      {:reply, {:error, :exists}, state}
    else
      new_list = %Services.Task.List{id: id, description: desc, tasks: []}

      new_state =
        %{state | lists: Map.put(lists, id, new_list)}
        |> save_tasks()

      {:reply, id, new_state}
    end
  end

  @impl true
  def handle_call(:list_ids, _from, state) do
    {:reply, Map.keys(state.lists), state}
  end

  @impl true
  def handle_call({:get_list, list_id}, _from, state) do
    case Map.get(state.lists, list_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Services.Task.List{tasks: tasks} ->
        {:reply, tasks, state}
    end
  end

  @impl true
  def handle_call({:get_list_with_meta, list_id}, _from, state) do
    case Map.get(state.lists, list_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Services.Task.List{tasks: tasks, description: desc} ->
        {:reply, {:ok, tasks, desc}, state}
    end
  end

  @impl true
  def handle_call({:peek_task, list_id}, _from, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %Services.Task.List{tasks: tasks}} ->
        Enum.find(tasks, fn task -> task.outcome == :todo end)
        |> case do
          nil -> {:reply, {:error, :empty}, state}
          task -> {:reply, {:ok, task}, state}
        end
    end
  end

  @impl true
  def handle_call({:resolve, list_id, task_id, outcome, result}, _from, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:reply, :ok, state}

      {:ok, list = %Services.Task.List{}} ->
        updated_list = Services.Task.List.resolve(list, task_id, outcome, result)

        new_state =
          %{state | lists: Map.put(state.lists, list_id, updated_list)}
          |> save_tasks()

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:set_description, list_id, description}, _from, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %Services.Task.List{} = list} ->
        updated_list = %{list | description: description}

        new_state =
          %{state | lists: Map.put(state.lists, list_id, updated_list)}
          |> save_tasks()

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:get_description, list_id}, _from, state) do
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %Services.Task.List{description: description}} ->
        {:reply, {:ok, description}, state}
    end
  end

  @impl true
  def handle_cast({:push_task, list_id, task_id, task_data}, state) do
    # Silently ignore operations on nonexistent lists
    case Map.fetch(state.lists, list_id) do
      :error ->
        {:noreply, state}

      {:ok, list = %Services.Task.List{tasks: tasks}} ->
        if Enum.any?(tasks, &(&1.id == task_id)) do
          {:noreply, state}
        else
          task = new_task(task_id, task_data)
          updated_list = Services.Task.List.push(list, task)

          %{state | lists: Map.put(state.lists, list_id, updated_list)}
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

      {:ok, list = %Services.Task.List{tasks: tasks}} ->
        if Enum.any?(tasks, &(&1.id == task_id)) do
          {:noreply, state}
        else
          task = new_task(task_id, task_data)
          updated_list = Services.Task.List.add(list, task)

          %{state | lists: Map.put(state.lists, list_id, updated_list)}
          |> save_tasks()
          |> then(&{:noreply, &1})
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------

  defp save_tasks(%{conversation_pid: pid, lists: lists} = state) do
    Enum.each(lists, fn {list_id, %Services.Task.List{tasks: tasks, description: desc}} ->
      Services.Conversation.upsert_task_list(pid, list_id, tasks)
      Services.Conversation.upsert_task_list_meta(pid, list_id, desc)
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
            %{task | outcome: Services.Task.Util.normalize_outcome(task.outcome)}
          end)
          |> then(&{task_list_id, &1})
      end
    end)
    |> Map.new()
  end
end
