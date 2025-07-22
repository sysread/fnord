defmodule ConversationServer do
  use GenServer

  alias Store.Project.Conversation

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def load(nil), do: :ok

  def load(conversation_id) do
    UI.debug("[conversation-server] restoring existing conversation", conversation_id)
    GenServer.cast(__MODULE__, {:load, conversation_id})
  end

  def append_msg(new_msg) do
    GenServer.cast(__MODULE__, {:append_msg, new_msg})
  end

  def replace_msgs(new_msgs) do
    GenServer.cast(__MODULE__, {:replace_msgs, new_msgs})
  end

  def get_conversation() do
    GenServer.call(__MODULE__, :get_conversation)
  end

  def get_messages() do
    GenServer.call(__MODULE__, :get_messages)
  end

  def save() do
    UI.debug("[conversation-server] saving conversation")
    GenServer.call(__MODULE__, :save)
  end

  # -----------------------------------------------------------------------------
  # Server API
  # -----------------------------------------------------------------------------
  def init(_), do: new()

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
  defp new() do
    {:ok, %{conversation: Conversation.new(), msgs: [], ts: nil}}
  end

  defp new(conversation_id) do
    conversation = Conversation.new(conversation_id)

    with {:ok, ts, msgs} <- Conversation.read(conversation) do
      {:ok, %{conversation: conversation, msgs: msgs, ts: ts}}
    end
  end
end
