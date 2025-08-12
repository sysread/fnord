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
    UI.debug("[conversation-server]", "saving conversation")
    GenServer.call(pid, :save)
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
  defp new(), do: {:ok, %{conversation: Conversation.new(), msgs: [], ts: nil}}
  defp new(nil), do: new()

  defp new(id) do
    conversation = Conversation.new(id)

    with {:ok, ts, msgs} <- Conversation.read(conversation) do
      {:ok, %{conversation: conversation, msgs: msgs, ts: ts}}
    end
  end
end
