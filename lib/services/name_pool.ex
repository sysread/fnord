defmodule Services.NamePool do
  @moduledoc """
  A service that manages a pool of AI agent names, batch-allocating them from
  the nomenclater for efficiency. Names can be checked out and optionally
  checked back in for reuse within the same session.

  Each checked-out name is now associated with the caller's `pid`, and you can
  retrieve it via `get_name_by_pid/1`.

  The pool allocates names in chunks sized to the configured workers setting to
  maximize API efficiency without overwhelming the connection pool.
  """

  use GenServer

  @name_chunk_timeout_ms Application.compile_env(:fnord, :name_chunk_timeout_ms, 30_000)

  @name __MODULE__

  @type t :: %__MODULE__{
          available: [String.t()],
          checked_out: MapSet.t(String.t()),
          all_used: MapSet.t(String.t()),
          chunk_size: pos_integer(),
          pid_to_name: %{optional(pid()) => String.t()},
          name_to_pid: %{optional(String.t()) => pid()}
        }

  defstruct available: [],
            checked_out: MapSet.new(),
            all_used: MapSet.new(),
            chunk_size: 12,
            pid_to_name: %{},
            name_to_pid: %{}

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------
  @default_name "Fnord Prefect"

  def default_name, do: @default_name

  @doc "Starts the name pool service"
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    init_opts = Keyword.drop(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Checks out a name from the pool. If the pool is empty or running low,
  automatically allocates a new chunk of names.

  Returns `{:ok, name}` or `{:error, reason}`.
  """
  @spec checkout_name(atom() | pid()) :: {:ok, String.t()} | {:error, String.t()}
  def checkout_name(server \\ @name) do
    GenServer.call(server, :checkout_name, 30_000)
  end

  @doc """
  Checks a name back into the pool for potential reuse. This is optional -
  names that are never checked back in will simply be lost when the session ends.
  """
  @spec checkin_name(String.t(), atom() | pid()) :: :ok
  def checkin_name(name, server \\ @name)

  def checkin_name(@default_name, _), do: :ok

  def checkin_name(name, server) do
    GenServer.cast(server, {:checkin_name, name})
  end

  @doc """
  Restores the association between a `pid` and a `name`. This is useful to
  re-associate a name after a process restart or similar event.
  """
  def associate_name(name, server \\ @name)

  def associate_name(nil, _), do: :ok

  def associate_name(name, server) do
    GenServer.call(server, {:associate_name, name})
  end

  @doc "Returns pool statistics for debugging/monitoring"
  def pool_stats(server \\ @name) do
    GenServer.call(server, :pool_stats)
  end

  @doc "Resets the pool state (mainly for testing)"
  def reset(server \\ @name) do
    GenServer.call(server, :reset)
  end

  @doc """
  Returns `{:ok, name}` if the given `pid` has a checked‐out name,
  or `{:error, :not_found}` otherwise.
  """
  @spec get_name_by_pid(pid(), atom() | pid()) :: {:ok, String.t()} | {:error, :not_found}
  def get_name_by_pid(pid, server \\ @name) when is_pid(pid) do
    GenServer.call(server, {:get_name_by_pid, pid})
  end

  # -----------------------------------------------------------------------------
  # GenServer Callbacks
  # -----------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    chunk_size =
      Application.get_env(:fnord, :workers, 12)

    state = %__MODULE__{
      available: [],
      checked_out: MapSet.new(),
      all_used: MapSet.new(),
      chunk_size: chunk_size,
      pid_to_name: %{},
      name_to_pid: %{}
    }

    {:ok, state}
  end

  @impl GenServer

  def handle_call(:checkout_name, {caller_pid, _ref}, state) do
    case ensure_names_available(state) do
      {:ok, updated_state} ->
        case updated_state.available do
          [name | remaining] ->
            new_state = %{
              updated_state
              | available: remaining,
                checked_out: MapSet.put(updated_state.checked_out, name),
                pid_to_name: Map.put(updated_state.pid_to_name, caller_pid, name),
                name_to_pid: Map.put(updated_state.name_to_pid, name, caller_pid)
            }

            {:reply, {:ok, name}, new_state}

          [] ->
            UI.error("Unable to allocate names from pool")
            {:reply, {:error, "No names available"}, updated_state}
        end

      {:error, reason} ->
        UI.error("Failed to ensure names available", reason)
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:associate_name, name}, {caller_pid, _ref}, state) do
    prev_pid = Map.get(state.name_to_pid, name)

    state =
      case prev_pid do
        nil ->
          state

        ^caller_pid ->
          state

        other ->
          %{
            state
            | pid_to_name: Map.delete(state.pid_to_name, other),
              name_to_pid: Map.delete(state.name_to_pid, name)
          }
      end

    new_state = %{
      state
      | checked_out: MapSet.put(state.checked_out, name),
        pid_to_name: Map.put(state.pid_to_name, caller_pid, name),
        name_to_pid: Map.put(state.name_to_pid, name, caller_pid),
        available: List.delete(state.available, name)
    }

    {:reply, :ok, new_state}
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
    new_state = %{
      state
      | available: [],
        checked_out: MapSet.new(),
        all_used: MapSet.new(),
        pid_to_name: %{},
        name_to_pid: %{}
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:get_name_by_pid, pid}, _from, state) do
    case Map.fetch(state.pid_to_name, pid) do
      {:ok, name} ->
        {:reply, {:ok, name}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_cast({:checkin_name, name}, state) do
    if MapSet.member?(state.checked_out, name) do
      pid = Map.get(state.name_to_pid, name)

      new_state = %{
        state
        | available: [name | state.available],
          checked_out: MapSet.delete(state.checked_out, name),
          pid_to_name: Map.delete(state.pid_to_name, pid),
          name_to_pid: Map.delete(state.name_to_pid, name)
      }

      {:noreply, new_state}
    else
      UI.warn("Attempted to check in name that wasn't checked out", name)
      {:noreply, state}
    end
  end

  @doc false
  # Ensures there are names available, allocating a new chunk if the pool is empty
  defp ensure_names_available(%__MODULE__{available: []} = state) do
    allocate_name_chunk(state)
  end

  defp ensure_names_available(state) do
    {:ok, state}
  end

  # Allocates a chunk of names from the nomenclater
  defp allocate_name_chunk(state) do
    Application.get_env(:fnord, :nomenclater, :real)
    |> case do
      :fake ->
        start_num = MapSet.size(state.all_used) + 1
        end_num = start_num + state.chunk_size - 1

        names =
          start_num..end_num
          |> Enum.map(&"NPC ##{&1}")

        new_state = %{
          state
          | available: names ++ state.available,
            all_used: MapSet.union(state.all_used, MapSet.new(names))
        }

        {:ok, new_state}

      :real ->
        used_names = MapSet.to_list(state.all_used)

        task =
          Task.async(fn ->
            AI.Agent.Nomenclater
            # `named?: false` prevents circular dependency with ourselves
            |> AI.Agent.new(named?: false)
            |> AI.Agent.get_response(%{
              want: state.chunk_size,
              used: used_names
            })
          end)

        # Use Task.yield to allow configurable timeout
        case Task.yield(task, @name_chunk_timeout_ms) do
          {:ok, {:ok, names}} when is_list(names) ->
            new_state = %{
              state
              | available: names ++ state.available,
                all_used: MapSet.union(state.all_used, MapSet.new(names))
            }

            {:ok, new_state}

          {:ok, {:error, reason}} ->
            UI.error("Failed to make up names for your agents", reason)
            {:error, reason}

          nil ->
            Task.shutdown(task, :brutal_kill)
            UI.error("Name allocation task timed out")
            {:error, :timeout}
        end
    end
  end
end
