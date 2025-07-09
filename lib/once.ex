defmodule Once do
  use GenServer

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def warn(msg) do
    GenServer.call(__MODULE__, {:warn, msg})
  end

  # -----------------------------------------------------------------------------
  # GenServer Callbacks
  # -----------------------------------------------------------------------------
  def init(_) do
    {:ok, %{}}
  end

  def handle_call({:warn, msg}, _from, state) do
    if Map.get(state, msg) do
      {:reply, :ok, state}
    else
      UI.warn(msg)
      {:reply, :ok, Map.put(state, msg, true)}
    end
  end
end
