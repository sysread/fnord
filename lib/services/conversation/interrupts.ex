defmodule Services.Conversation.Interrupts do
  @moduledoc """
  Queue for injecting user messages into a conversation mid-completion.

  This GenServer stores a FIFO list of pending injected user messages per
  conversation pid. AI.Completion will drain and apply these messages at safe
  checkpoints before sending a model request or between tool-call rounds.
  """
  use GenServer

  @type msg :: AI.Util.msg()

  @doc """
  Start the interrupt queue server.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc """
  Enqueue an injected user message for the given conversation pid.
  """
  @spec request(pid(), String.t()) :: :ok
  def request(conversation_pid, content)
      when is_pid(conversation_pid) and
             is_binary(content) do
    msg = AI.Util.user_msg("[User Interjection] " <> content)
    GenServer.cast(__MODULE__, {:enqueue, conversation_pid, msg})
    :ok
  end

  @doc """
  Drain all pending injected messages for a conversation.
  Returns an empty list if none are pending.
  """
  @spec take_all(pid()) :: [msg]
  def take_all(conversation_pid) when is_pid(conversation_pid) do
    GenServer.call(__MODULE__, {:take_all, conversation_pid})
  end

  @doc """
  Returns true if any interrupts are pending for the conversation pid.
  """
  @spec pending?(pid()) :: boolean()
  def pending?(conversation_pid) when is_pid(conversation_pid) do
    GenServer.call(__MODULE__, {:pending, conversation_pid})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------
  @impl true
  @spec init(map()) :: {:ok, map()}
  def init(state), do: {:ok, state}

  @impl true
  @spec handle_cast({:enqueue, pid(), msg}, map()) :: {:noreply, map()}
  def handle_cast({:enqueue, pid, msg}, state) do
    {:noreply, Map.update(state, pid, [msg], fn list -> list ++ [msg] end)}
  end

  @impl true
  @spec handle_call({:take_all, pid()}, GenServer.from(), map()) :: {:reply, [msg], map()}
  def handle_call({:take_all, pid}, _from, state) do
    {msgs, new_state} = Map.pop(state, pid, [])
    {:reply, msgs, new_state}
  end

  @impl true
  @spec handle_call({:pending, pid()}, GenServer.from(), map()) :: {:reply, boolean(), map()}
  def handle_call({:pending, pid}, _from, state) do
    {:reply, Map.has_key?(state, pid), state}
  end
end
