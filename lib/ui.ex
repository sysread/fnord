defmodule UI do
  use GenServer

  defstruct [
    :id_counter,
    :statuses
  ]

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def add_status(msg, detail \\ nil) do
    GenServer.call(__MODULE__, {:add_status, msg, detail})
  end

  def complete_status(status_id, resolution) do
    GenServer.cast(__MODULE__, {:complete_status, status_id, resolution})
  end

  def complete_status(status_id, resolution, append) do
    GenServer.cast(__MODULE__, {:complete_status, status_id, resolution, append})
  end

  def puts(msg) do
    Owl.IO.puts(msg)
    Owl.LiveScreen.await_render()
  end

  # -----------------------------------------------------------------------------
  # Server callbacks
  # -----------------------------------------------------------------------------
  @impl true
  def init(_) do
    state = %__MODULE__{
      id_counter: 0,
      statuses: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add_status, msg, detail}, _from, state) do
    {state, status_id} = do_add_status(state, msg, detail)
    {:reply, status_id, state}
  end

  @impl true
  def handle_cast({:complete_status, status_id, resolution}, state) do
    {:noreply, do_complete_status(state, status_id, resolution)}
  end

  @impl true
  def handle_cast({:complete_status, status_id, resolution, msg}, state) do
    {:noreply, do_complete_status(state, status_id, resolution, msg)}
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp interactive?(), do: IO.ANSI.enabled?()

  defp do_add_status(state, msg, detail) do
    msg =
      if is_nil(detail) do
        msg
      else
        Owl.Data.tag(
          [msg, ": ", Owl.Data.tag(detail, :green)],
          :default_color
        )
        |> Owl.Data.to_chardata()
      end

    counter = state.id_counter + 1
    status_id = String.to_atom("status_#{counter}")
    statuses = Map.put(state.statuses, status_id, msg)

    if interactive?() do
      Owl.Spinner.start(id: status_id)
      Owl.Spinner.update_label(id: status_id, label: msg)
      Owl.LiveScreen.await_render()
    end

    {
      %__MODULE__{state | id_counter: counter, statuses: statuses},
      status_id
    }
  end

  defp do_complete_status(state, status_id, resolution, msg \\ nil) do
    status = Map.get(state.statuses, status_id)
    state = %{state | statuses: Map.delete(state.statuses, status_id)}

    msg =
      if is_nil(msg) do
        status
      else
        status <> ": " <> msg
      end

    if interactive?() do
      Owl.Spinner.stop(id: status_id, resolution: resolution, label: msg)
      Owl.LiveScreen.await_render()
    end

    state
  end
end
