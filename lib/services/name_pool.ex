defmodule Services.NamePool do
  @moduledoc """
  A service that manages a pool of AI agent names, batch-allocating them from 
  the nomenclater for efficiency. Names can be checked out and optionally 
  checked back in for reuse within the same session.

  The pool allocates names in chunks sized to the configured workers setting
  to maximize API efficiency without overwhelming the connection pool.
  """

  use GenServer
  require Logger

  @name __MODULE__

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            available: [String.t()],
            checked_out: MapSet.t(String.t()),
            all_used: MapSet.t(String.t()),
            chunk_size: pos_integer()
          }

    defstruct available: [], checked_out: MapSet.new(), all_used: MapSet.new(), chunk_size: 12
  end

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------

  @doc "Starts the name pool service"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Checks out a name from the pool. If the pool is empty or running low,
  automatically allocates a new chunk of names.

  Returns `{:ok, name}` or `{:error, reason}`.
  """
  @spec checkout_name() :: {:ok, String.t()} | {:error, String.t()}
  def checkout_name do
    GenServer.call(@name, :checkout_name, 30_000)
  end

  @doc """
  Checks a name back into the pool for potential reuse. This is optional -
  names that are never checked back in will simply be lost when the session ends.
  """
  @spec checkin_name(String.t()) :: :ok
  def checkin_name(name) when is_binary(name) do
    GenServer.cast(@name, {:checkin_name, name})
  end

  @doc "Returns pool statistics for debugging/monitoring"
  def pool_stats do
    GenServer.call(@name, :pool_stats)
  end

  @doc "Resets the pool state (mainly for testing)"
  def reset do
    GenServer.call(@name, :reset)
  end

  # -----------------------------------------------------------------------------
  # GenServer Callbacks
  # -----------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    chunk_size = Application.get_env(:fnord, :workers, 12)

    state = %State{
      available: [],
      checked_out: MapSet.new(),
      all_used: MapSet.new(),
      chunk_size: chunk_size
    }

    Logger.debug("NamePool started with chunk_size=#{chunk_size}")
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:checkout_name, _from, state) do
    case ensure_names_available(state) do
      {:ok, updated_state} ->
        case updated_state.available do
          [name | remaining] ->
            new_state = %{
              updated_state
              | available: remaining,
                checked_out: MapSet.put(updated_state.checked_out, name)
            }

            Logger.debug("Checked out name: #{name} (#{length(remaining)} remaining)")
            {:reply, {:ok, name}, new_state}

          [] ->
            Logger.error("Unable to allocate names from pool")
            {:reply, {:error, "No names available"}, updated_state}
        end

      {:error, reason} ->
        Logger.error("Failed to ensure names available: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:pool_stats, _from, state) do
    stats = %{
      available_count: length(state.available),
      checked_out_count: MapSet.size(state.checked_out),
      all_used_count: MapSet.size(state.all_used),
      chunk_size: state.chunk_size
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    new_state = %{state | available: [], checked_out: MapSet.new(), all_used: MapSet.new()}
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_cast({:checkin_name, name}, state) do
    if MapSet.member?(state.checked_out, name) do
      new_state = %{
        state
        | available: [name | state.available],
          checked_out: MapSet.delete(state.checked_out, name)
      }

      Logger.debug("Checked in name: #{name} (#{length(new_state.available)} available)")
      {:noreply, new_state}
    else
      Logger.warning("Attempted to check in name that wasn't checked out: #{name}")
      {:noreply, state}
    end
  end

  # -----------------------------------------------------------------------------
  # Private Functions
  # -----------------------------------------------------------------------------

  # Ensures we have at least one name available, allocating a new chunk if needed
  defp ensure_names_available(state) do
    if length(state.available) > 0 do
      {:ok, state}
    else
      Logger.info("Name pool empty, allocating new chunk of #{state.chunk_size} names")
      allocate_name_chunk(state)
    end
  end

  # Allocates a chunk of names from the nomenclater
  defp allocate_name_chunk(state) do
    used_names = MapSet.to_list(state.all_used)

    case AI.Agent.Nomenclater.get_names(state.chunk_size, used_names) do
      {:ok, names} when is_list(names) ->
        Logger.info("Allocated #{length(names)} names to pool")

        new_state = %{
          state
          | available: names ++ state.available,
            all_used: MapSet.union(state.all_used, MapSet.new(names))
        }

        {:ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to allocate names: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
