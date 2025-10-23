defmodule Services.Conversation.Interrupts do
  @moduledoc """
  Queue for injecting user messages into a conversation mid-completion.

  This GenServer stores a FIFO list of pending injected user messages per
  conversation pid. AI.Completion will drain and apply these messages at safe
  checkpoints before sending a model request or between tool-call rounds.

  Additionally, it supports temporarily blocking interrupts for a conversation
  during critical phases (e.g., finalization). When blocked, attempts to
  interrupt should be rejected at the UI layer; this server tracks blocked state
  so callers can check/decide behavior.
  """
  use GenServer

  @type msg :: AI.Util.msg()

  @type state :: %{
          queues: %{optional(pid()) => [msg]},
          blocked: MapSet.t()
        }

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
  def init(_state), do: {:ok, %{queues: %{}, blocked: MapSet.new()}}

  @impl true
  @spec handle_cast({:enqueue, pid(), msg}, state) :: {:noreply, state}
  def handle_cast({:enqueue, pid, msg}, %{queues: queues} = state) do
    new_queues = Map.update(queues, pid, [msg], fn list -> list ++ [msg] end)
    {:noreply, %{state | queues: new_queues}}
  end

  @impl true
  @spec handle_cast({:block, pid()}, state) :: {:noreply, state}
  def handle_cast({:block, pid}, %{blocked: blocked} = state) do
    {:noreply, %{state | blocked: MapSet.put(blocked, pid)}}
  end

  @impl true
  @spec handle_cast({:unblock, pid()}, state) :: {:noreply, state}
  def handle_cast({:unblock, pid}, %{blocked: blocked} = state) do
    {:noreply, %{state | blocked: MapSet.delete(blocked, pid)}}
  end

  @impl true
  @spec handle_call({:take_all, pid()}, GenServer.from(), state) :: {:reply, [msg], state}
  def handle_call({:take_all, pid}, _from, %{queues: queues} = state) do
    {msgs, new_queues} = Map.pop(queues, pid, [])
    {:reply, msgs, %{state | queues: new_queues}}
  end

  @impl true
  @spec handle_call({:pending, pid()}, GenServer.from(), state) :: {:reply, boolean(), state}
  def handle_call({:pending, pid}, _from, %{queues: queues} = state) do
    {:reply, Map.has_key?(queues, pid), state}
  end

  @impl true
  @spec handle_call({:blocked?, pid()}, GenServer.from(), state) :: {:reply, boolean(), state}
  def handle_call({:blocked?, pid}, _from, %{blocked: blocked} = state) do
    {:reply, MapSet.member?(blocked, pid), state}
  end

  # ---------------------------------------------------------------------------
  # Public API for blocking
  # ---------------------------------------------------------------------------
  @doc """
  Block interrupts for a given conversation pid.
  """
  @spec block(pid()) :: :ok
  def block(conversation_pid) when is_pid(conversation_pid) do
    GenServer.cast(__MODULE__, {:block, conversation_pid})
  end

  @doc """
  Unblock interrupts for a given conversation pid.
  """
  @spec unblock(pid()) :: :ok
  def unblock(conversation_pid) when is_pid(conversation_pid) do
    GenServer.cast(__MODULE__, {:unblock, conversation_pid})
  end

  @doc """
  Return true if interrupts are currently blocked for conversation pid.
  """
  @spec blocked?(pid()) :: boolean()
  def blocked?(conversation_pid) when is_pid(conversation_pid) do
    GenServer.call(__MODULE__, {:blocked?, conversation_pid})
  end
end
