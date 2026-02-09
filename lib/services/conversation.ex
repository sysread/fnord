defmodule Services.Conversation do
  import AI.Util

  use GenServer

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  @spec start_link() :: GenServer.on_start()
  def start_link(conversation_id \\ nil) do
    GenServer.start_link(__MODULE__, conversation_id)
  end

  @doc """
  Get the conversation ID of the current conversation.
  """
  @spec get_id(pid) :: binary()
  def get_id(pid) do
    GenServer.call(pid, :get_id)
  end

  @doc """
  Load an existing conversation from persistent storage. If `conversation_id`
  is `nil`, a new conversation is created. If a conversation with the given ID
  does not exist or is corrupt, an error is returned.
  """
  @spec load(binary | nil, pid) :: :ok | {:error, any}
  def load(nil, _pid), do: :ok

  def load(conversation_id, pid) do
    GenServer.cast(pid, {:load, conversation_id})
  end

  @doc """
  Append a new message to the conversation.
  Does not save the conversation.
  """
  @spec append_msg(AI.Util.msg(), pid) :: :ok
  def append_msg(new_msg, pid) do
    GenServer.cast(pid, {:append_msg, new_msg})
  end

  @doc """
  Replace all messages in the conversation with a new list of messages.
  This does not save the conversation.
  """
  @spec replace_msgs([AI.Util.msg()], pid) :: :ok
  def replace_msgs(new_msgs, pid) do
    GenServer.cast(pid, {:replace_msgs, new_msgs})
  end

  @doc """
  Get the current agent instance.
  """
  @spec get_agent(pid) :: AI.Agent.t()
  def get_agent(pid) do
    GenServer.call(pid, :get_agent)
  end

  @doc """
  Get the current conversation object.
  """
  @spec get_conversation(pid) :: Store.Project.Conversation.t()
  def get_conversation(pid) do
    GenServer.call(pid, :get_conversation)
  end

  @doc """
  Get the list of messages in the current conversation.
  """
  @spec get_messages(pid) :: [AI.Util.msg()]
  def get_messages(pid) do
    GenServer.call(pid, :get_messages)
  end

  @doc """
  Get the conversation metadata.
  """
  @spec get_metadata(pid) :: map
  def get_metadata(pid) do
    GenServer.call(pid, :get_metadata)
  end

  @doc """
  Get the current session memory list for this conversation.
  """
  @spec get_memory(pid) :: list
  def get_memory(pid) do
    GenServer.call(pid, :get_memory)
  end

  @doc """
  Replace the session memory list for this conversation.

  This does not save the conversation to disk; callers should invoke `save/1`
  if they want the updated memory list to be persisted.
  """
  @spec put_memory(pid, list) :: :ok
  def put_memory(pid, memory) when is_list(memory) do
    GenServer.cast(pid, {:set_memory, memory})
  end

  @doc """
  Get all task lists for this conversation.
  """
  @spec get_task_lists(pid) :: [binary()]
  def get_task_lists(pid) do
    GenServer.call(pid, :get_task_lists)
  end

  @doc """
  Get the task list with the given ID for this conversation.
  """
  @spec get_task_list(pid, binary()) :: Services.Task.task_list() | nil
  def get_task_list(pid, task_list_id) do
    GenServer.call(pid, {:get_task_list, task_list_id})
  end

  @doc """
  Get the metadata for the given task list (currently only description).
  Returns {:ok, description} | {:error, :not_found}
  """
  @spec get_task_list_meta(pid, binary()) :: {:ok, map()} | {:error, :not_found}
  def get_task_list_meta(pid, task_list_id) do
    GenServer.call(pid, {:get_task_list_meta, task_list_id})
  end

  @doc """
  Upsert the metadata for the given task list (now a map with at least :description).
  """
  @spec upsert_task_list_meta(pid, binary(), map() | binary | nil) :: :ok | {:error, :not_found}
  def upsert_task_list_meta(pid, task_list_id, meta) when is_map(meta) do
    GenServer.call(pid, {:upsert_task_list_meta, task_list_id, meta})
  end

  def upsert_task_list_meta(pid, task_list_id, description) do
    # Backwards-compat: accept a raw description and wrap it into a map
    GenServer.call(pid, {:upsert_task_list_meta, task_list_id, %{description: description}})
  end

  @doc """
  Upsert (insert or update) the given task list in the conversation's task
  store, replacing any existing list with the same ID.
  """
  @spec upsert_task_list(pid, binary(), Services.Task.task_list()) :: :ok
  def upsert_task_list(pid, task_list_id, tasks) do
    GenServer.call(pid, {:upsert_task_list, task_list_id, tasks})
  end

  @doc """
  Save the current conversation to persistent storage. This updates the
  conversation's timestamp and writes the messages to disk. If the conversation
  is successfully saved, the server state is reloaded with the latest data.
  """
  @spec save(pid) :: {:ok, Store.Project.Conversation.t()} | {:error, any}
  def save(pid) do
    GenServer.call(pid, :save)
  end

  @doc """
  Request an interrupt by enqueuing a new user message to be injected at the next safe point.
  """
  @spec interrupt(pid, String.t()) :: :ok | {:error, any}
  def interrupt(pid, content) do
    Services.Conversation.Interrupts.request(pid, content)
  end

  @doc """
  Get a response from the AI.Agent.Coordinator. The `opts` is passed directly
  to `AI.Agent.get_response/2` after converting to a map and adding the
  conversation server's PID under `:conversation_pid`.
  """
  @spec get_response(pid, keyword) :: {:ok, any} | {:error, any}
  def get_response(pid, opts) do
    args =
      opts
      |> Enum.into(%{})
      |> Map.put(:conversation_pid, pid)

    pid
    |> get_agent()
    |> AI.Agent.get_response(args)
  end

  # -----------------------------------------------------------------------------
  # Server API
  # -----------------------------------------------------------------------------
  @impl true
  def init(id), do: new(id)

  @impl true
  def handle_cast({:load, id}, state) do
    with {:ok, new_state} <- new(id) do
      {:noreply, new_state}
    else
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_cast({:append_msg, new_msg}, state) do
    {:noreply, %{state | msgs: state.msgs ++ [new_msg]}}
  end

  def handle_cast({:replace_msgs, new_msgs}, state) do
    {:noreply, %{state | msgs: new_msgs}}
  end

  def handle_cast({:set_memory, memory}, state) when is_list(memory) do
    {:noreply, %{state | memory: memory}}
  end

  @impl true
  def handle_call(:get_id, _from, state) do
    {:reply, state.conversation.id, state}
  end

  @impl true
  def handle_call(:get_agent, _from, state) do
    {:reply, state.agent, state}
  end

  @impl true
  def handle_call(:get_conversation, _from, state) do
    {:reply, state.conversation, state}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.msgs, state}
  end

  @impl true
  def handle_call(:get_metadata, _from, state) do
    {:reply, state.metadata, state}
  end

  @impl true
  def handle_call(:get_memory, _from, state) do
    {:reply, state.memory, state}
  end

  @impl true
  def handle_call(:get_task_lists, _from, state) do
    {:reply, Map.keys(state.tasks), state}
  end

  @impl true
  def handle_call({:get_task_list, task_list_id}, _from, state) do
    # Tasks are always stored as %{tasks: [...], description: ...} after normalization on read
    reply =
      case Map.get(state.tasks, task_list_id) do
        %{tasks: tasks} -> tasks
        _ -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:upsert_task_list, task_list_id, tasks}, _from, state) do
    # Preserve existing description if present, otherwise store with nil description
    existing_entry = Map.get(state.tasks, task_list_id)

    new_entry =
      case existing_entry do
        %{description: desc} -> %{tasks: tasks, description: desc}
        _ -> %{tasks: tasks, description: nil}
      end

    {:reply, :ok, %{state | tasks: Map.put(state.tasks, task_list_id, new_entry)}}
  end

  @impl true
  def handle_call({:get_task_list_meta, list_id}, _from, state) do
    case Map.fetch(state.tasks, list_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{description: desc} = entry} ->
        # Return the meta map: description and optional status (string)
        meta = %{description: desc, status: Map.get(entry, :status)}
        {:reply, {:ok, meta}, state}
    end
  end

  @impl true
  def handle_call({:upsert_task_list_meta, list_id, meta}, _from, state) do
    # meta is expected to be a map with at least :description; callers may pass a raw description elsewhere
    case Map.fetch(state.tasks, list_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, entry} when is_map(meta) ->
        # Merge existing entry with provided meta keys (description/status)
        new_entry =
          entry
          |> Map.put(:description, Map.get(meta, :description))
          |> Map.put(:status, Map.get(meta, :status))

        new_state = %{state | tasks: Map.put(state.tasks, list_id, new_entry)}
        {:reply, :ok, new_state}

      {:ok, entry} ->
        # Fallback: if meta isn't a map, treat it as description
        new_entry = %{entry | description: meta}
        new_state = %{state | tasks: Map.put(state.tasks, list_id, new_entry)}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:save, _from, state) do
    data = %{
      # Before persisting, strip boilerplate messages
      messages: filter_boilerplate(state.msgs),
      metadata: state.metadata,
      memory: state.memory,
      tasks: state.tasks
    }

    with {:ok, conversation} <- Store.Project.Conversation.write(state.conversation, data),
         {:ok, state} <- new(state.conversation.id) do
      {:reply, {:ok, conversation}, state}
    else
      other -> {:reply, other, state}
    end
  end

  # -----------------------------------------------------------------------------
  # Internals
  # -----------------------------------------------------------------------------
  defp new() do
    # Afikoman: override agent name when in "fonz mode"
    agent_args =
      if Settings.get_yes_count() > 1 do
        [named?: true, name: "The Fonz"]
      else
        [named?: true]
      end

    {:ok,
     %{
       agent: AI.Agent.new(AI.Agent.Coordinator, agent_args),
       conversation: Store.Project.Conversation.new(),
       msgs: [],
       metadata: %{},
       ts: nil,
       memory: [],
       tasks: %{}
     }}
  end

  defp new(nil), do: new()

  defp new(id) do
    conversation = Store.Project.Conversation.new(id)

    with {:ok, data} <- Store.Project.Conversation.read(conversation) do
      %{
        timestamp: ts,
        messages: msgs,
        metadata: metadata,
        memory: memory,
        tasks: tasks
      } = data

      agent_args =
        msgs
        |> find_agent_name()
        |> case do
          nil -> [named?: true]
          name -> [named?: true, name: name]
        end

      # Afikoman: override agent name when in "fonz mode"
      agent_args =
        if Settings.get_yes_count() > 1 do
          [named?: true, name: "The Fonz"]
        else
          agent_args
        end

      agent = AI.Agent.new(AI.Agent.Coordinator, agent_args)

      {:ok,
       %{
         agent: agent,
         conversation: conversation,
         ts: ts,
         msgs: msgs,
         metadata: metadata,
         memory: memory,
         tasks: tasks
       }}
    end
  end

  defp find_agent_name(msgs) do
    re = ~r/^Your name is (.*)\.$/

    msgs
    |> Enum.find_value(fn
      %{content: content} = msg when is_system_msg?(msg) ->
        case Regex.run(re, content) do
          [_, name] -> name
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  @re_name_msg ~r/^Your name is (.*)\.$/
  @re_summary_msg ~r/^Summary of conversation and research thus far:/
  @re_reasoning_msg ~r/^<think>/

  @spec filter_boilerplate([AI.Util.msg()]) :: [AI.Util.msg()]
  defp filter_boilerplate(msgs) do
    msgs
    |> Enum.filter(fn
      # ...filter boilerplate system/developer messages
      %{content: c} = msg when is_system_msg?(msg) ->
        cond do
          # ...preserve the agent name-line to avoid churn
          Regex.run(@re_name_msg, c) != nil -> true
          # ...preserve compactor summary so follow-ups and replays retain the compressed context
          Regex.run(@re_summary_msg, c) != nil -> true
          # ...drop other system scaffolding
          true -> false
        end

      # ...drop reasoning messages
      %{role: "assistant", content: c} when is_binary(c) ->
        @re_reasoning_msg
        |> Regex.run(c)
        |> is_nil()

      # ...keep everything else
      _ ->
        true
    end)
  end
end
