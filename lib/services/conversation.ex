defmodule Services.Conversation do
  use GenServer

  alias Store.Project.Conversation

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
  Append a new message to the conversation. Does not save the conversation.
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
  @spec get_conversation(pid) :: Conversation.t()
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
  Strengthen the memory mutation for the given memory ID.
  """
  @spec bump_memory_mutation(pid, String.t()) :: non_neg_integer
  def bump_memory_mutation(pid, memory_id) do
    bump_memory_mutation(pid, memory_id, :strengthen)
  end

  @spec bump_memory_mutation(pid, String.t(), :strengthen | :weaken) :: non_neg_integer
  def bump_memory_mutation(pid, memory_id, op) do
    GenServer.call(pid, {:bump_memory_mutation, memory_id, op})
  end

  @doc """
  Save the current conversation to persistent storage. This updates the
  conversation's timestamp and writes the messages to disk. If the conversation
  is successfully saved, the server state is reloaded with the latest data.
  """
  @spec save(pid) :: {:ok, Conversation.t()} | {:error, any}
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
  `:conversation` server's `pid`.
  """
  @spec get_response(pid, keyword) :: {:ok, any} | {:error, any}
  def get_response(pid, opts) do
    args =
      opts
      |> Enum.into(%{})
      |> Map.put(:conversation, pid)

    pid
    |> get_agent()
    |> AI.Agent.get_response(args)
  end

  # -----------------------------------------------------------------------------
  # Server API
  # -----------------------------------------------------------------------------
  def init(id), do: new(id)

  def handle_cast({:load, id}, state) do
    with {:ok, new_state} <- new(id) do
      {:noreply, new_state}
    else
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_cast({:append_msg, new_msg}, state) do
    new_msgs = state.msgs ++ [new_msg]
    new_metadata = update_memory_state(state.metadata, new_msgs)
    {:noreply, %{state | msgs: new_msgs, metadata: new_metadata}}
  end

  def handle_cast({:replace_msgs, new_msgs}, state) do
    {:noreply, %{state | msgs: new_msgs}}
  end

  def handle_call(:get_id, _from, state) do
    {:reply, state.conversation.id, state}
  end

  def handle_call(:get_agent, _from, state) do
    {:reply, state.agent, state}
  end

  def handle_call(:get_conversation, _from, state) do
    {:reply, state.conversation, state}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, state.msgs, state}
  end

  def handle_call(:get_metadata, _from, state) do
    {:reply, state.metadata, state}
  end

  def handle_call({:bump_memory_mutation, memory_id, op}, _from, state) do
    {new_metadata, count} = update_memory_mutations(state.metadata, memory_id, op)
    {:reply, count, %{state | metadata: new_metadata}}
  end

  def handle_call(:save, _from, state) do
    # Before persisting, strip recurring system prompts per settings
    msgs_to_write = filter_system_messages(state.msgs)

    with {:ok, conversation} <-
           Conversation.write(state.conversation, msgs_to_write, state.metadata),
         {:ok, state} <- new(state.conversation.id) do
      {:reply, {:ok, conversation}, state}
    else
      other -> {:reply, other, state}
    end
  end

  # -----------------------------------------------------------------------------
  # System message filtering
  # -----------------------------------------------------------------------------
  @spec filter_system_messages([AI.Util.msg()]) :: [AI.Util.msg()]
  defp filter_system_messages(msgs) do
    Enum.filter(msgs, fn
      %{role: "system", content: content} ->
        cond do
          # Preserve the agent name-line to avoid churn
          Regex.run(~r/^Your name is (.*)\.$/, content) != nil -> true
          # Preserve compactor summary so follow-ups and replays retain the compressed context
          String.starts_with?(content, "Summary of conversation and research thus far:") -> true
          # Drop other system scaffolding
          true -> false
        end

      _ ->
        true
    end)
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
       conversation: Conversation.new(),
       msgs: [],
       metadata: %{},
       ts: nil
     }}
  end

  defp new(nil), do: new()

  defp new(id) do
    conversation = Conversation.new(id)

    with {:ok, ts, msgs, metadata} <- Conversation.read(conversation) do
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
         msgs: msgs,
         metadata: metadata,
         ts: ts
       }}
    end
  end

  defp find_agent_name(msgs) do
    re = ~r/^Your name is (.*)\.$/

    msgs
    |> Enum.find_value(fn
      %{role: "system", content: content} ->
        re
        |> Regex.run(content)
        |> case do
          [_, name] -> name
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  # -----------------------------------------------------------------------------
  # Memory state management
  # -----------------------------------------------------------------------------

  @top_k_tokens 5000

  # Updates memory state with new messages. Filters to user/assistant roles,
  # tokenizes, stems, removes stopwords, and accumulates into bag-of-words.
  # Trims to top K tokens by frequency to prevent unbounded growth.
  defp update_memory_state(metadata, msgs) do
    memory_state = Map.get(metadata, "memory_state", %{})
    accumulated = Map.get(memory_state, "accumulated_tokens", %{})
    last_idx = Map.get(memory_state, "last_processed_index", -1)

    # Get messages we haven't processed yet
    new_messages =
      msgs
      |> Enum.drop(last_idx + 1)
      |> Enum.filter(fn msg ->
        Map.get(msg, :role) in ["user", "assistant"]
      end)

    # If no new messages to process, return unchanged metadata
    if Enum.empty?(new_messages) do
      metadata
    else
      # Extract and normalize text from new messages
      new_tokens =
        new_messages
        |> Enum.map(&Map.get(&1, :content, ""))
        |> Enum.join(" ")
        |> AI.Memory.normalize_to_tokens()

      # Merge into accumulated tokens
      updated_accumulated = AI.Memory.merge_tokens(accumulated, new_tokens)

      # Trim to prevent unbounded growth
      trimmed_accumulated = AI.Memory.trim_to_top_k(updated_accumulated, @top_k_tokens)

      # Calculate total tokens
      total_tokens = Enum.sum(Map.values(trimmed_accumulated))

      # Fetch memory mutations
      mutations = Map.get(memory_state, "memory_mutations", %{})

      # Update memory state
      updated_memory_state = %{
        "accumulated_tokens" => trimmed_accumulated,
        "last_processed_index" => length(msgs) - 1,
        "total_tokens" => total_tokens,
        "memory_mutations" => mutations
      }

      Map.put(metadata, "memory_state", updated_memory_state)
    end
  end

  @spec update_memory_mutations(map(), String.t(), :strengthen | :weaken) :: {map(), integer()}
  defp update_memory_mutations(metadata, memory_id, op) do
    memory_state = Map.get(metadata, "memory_state", %{})
    mutations = Map.get(memory_state, "memory_mutations", %{})
    current = Map.get(mutations, memory_id, 0)

    new_count =
      case op do
        :strengthen ->
          base = if current < 0, do: 0, else: current
          base + 1

        :weaken ->
          base = if current > 0, do: 0, else: current
          base - 1
      end

    new_mutations = Map.put(mutations, memory_id, new_count)
    new_memory_state = Map.put(memory_state, "memory_mutations", new_mutations)
    updated_metadata = Map.put(metadata, "memory_state", new_memory_state)
    {updated_metadata, new_count}
  end
end
