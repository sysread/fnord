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
    {:noreply, %{state | msgs: state.msgs ++ [new_msg]}}
  end

  def handle_cast({:replace_msgs, new_msgs}, state) do
    {:noreply, %{state | msgs: new_msgs}}
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

  def handle_call(:save, _from, state) do
    with {:ok, conversation} <- Conversation.write(state.conversation, state.msgs),
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
    {:ok,
     %{
       agent: AI.Agent.new(AI.Agent.Coordinator, named?: true),
       conversation: Conversation.new(),
       msgs: [],
       ts: nil
     }}
  end

  defp new(nil), do: new()

  defp new(id) do
    conversation = Conversation.new(id)

    with {:ok, ts, msgs} <- Conversation.read(conversation) do
      agent_args =
        msgs
        |> find_agent_name()
        |> case do
          nil -> [named?: true]
          name -> [named?: true, name: name]
        end

      agent = AI.Agent.new(AI.Agent.Coordinator, agent_args)

      {:ok,
       %{
         agent: agent,
         conversation: conversation,
         msgs: msgs,
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
end
