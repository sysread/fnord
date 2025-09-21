defmodule Services.Globals do
  @moduledoc """
  Drop-in-ish replacement for Application.(get|put)_env that *shadows* values
  down a process tree. Think: dynamic scope via process ancestry.

  - `put_env/3` sets an override in the *current tree* (installing the caller
     as a root if needed).
  - `get_env/3` first checks the current tree's overrides, then falls back to
    `Application.get_env/3`.
  - `delete_env/2` removes the tree-local override.
  """

  use GenServer

  @name __MODULE__

  @pd_root_key :globals_root_pid

  # set: pid -> true
  @roots_tab :globals_roots

  # set: {root_pid, app, key} -> value
  @data_tab :globals_data

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, @name)

    case GenServer.start_link(__MODULE__, :ok, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Put a tree-local override. Creates a root for the current process if none
  exists.
  """
  @spec put_env(atom, term, term) :: :ok
  def put_env(app, key, value) do
    root = ensure_root!()
    true = :ets.insert(@data_tab, {{root, app, key}, value})
    :ok
  end

  @doc """
  Get a value with tree-local shadowing, else falls back to
  `Application.get_env/3`.
  """
  @spec get_env(atom, term, term) :: term
  def get_env(app, key, default \\ nil) do
    case resolve_root() do
      nil ->
        Application.get_env(app, key, default)

      root ->
        case :ets.lookup(@data_tab, {root, app, key}) do
          [{{^root, ^app, ^key}, value}] -> value
          [] -> Application.get_env(app, key, default)
        end
    end
  end

  @doc """
  Delete a tree-local override (no-op if none). Returns :ok.
  """
  @spec delete_env(atom, term) :: :ok
  def delete_env(app, key) do
    case resolve_root() do
      nil ->
        :ok

      root ->
        :ets.delete(@data_tab, {root, app, key})
        :ok
    end
  end

  @doc """
  Install the caller as a shadowing root explicitly (rarely needed; put_env/3
  auto-installs).
  """
  @spec install_root() :: :ok
  def install_root() do
    GenServer.call(@name, {:install_root, self()})
  end

  @doc """
  Return the current shadowing root PID (or nil). Useful for debugging.
  """
  @spec current_root() :: pid | nil
  def current_root(), do: resolve_root()

  ## GenServer

  @impl true
  def init(:ok) do
    :ets.new(@roots_tab, [:named_table, :set, :public])
    :ets.new(@data_tab, [:named_table, :set, :public, :compressed, read_concurrency: true])
    # refs: ref -> pid
    {:ok, %{refs: %{}}}
  end

  @impl true
  def handle_call({:install_root, pid}, _from, s) do
    unless :ets.member(@roots_tab, pid) do
      ref = Process.monitor(pid)
      :ets.insert(@roots_tab, {pid, true})
      # cache root in caller PD so descendants resolve quickly
      if self() == pid, do: Process.put(@pd_root_key, pid)
      s = put_in(s.refs[ref], pid)
      {:reply, :ok, s}
    else
      {:reply, :ok, s}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refs: refs} = s) do
    case Map.pop(refs, ref) do
      {nil, _} ->
        {:noreply, s}

      {root, refs2} ->
        # Remove root marker
        :ets.delete(@roots_tab, root)
        # Wipe all overrides under this root
        # Match head: {{root, _app, _key}, _val}
        ms = [{{{root, :_, :_}, :_}, [], [true]}]
        _ = :ets.select_delete(@data_tab, ms)
        {:noreply, %{s | refs: refs2}}
    end
  end

  # ----------------------------------------------------------------------------
  # Internal
  # ----------------------------------------------------------------------------

  # Ensure there is a root for this process tree; if none, install self().
  defp ensure_root!() do
    case resolve_root() do
      nil ->
        :ok = install_root()
        self()

      pid ->
        pid
    end
  end

  # ----------------------------------------------------------------------------
  # Resolve the current root PID:
  # 1) PD cache
  # 2) Self as root (fast path)
  # 3) Walk :"$ancestors" for first PID in @roots_tab
  # ----------------------------------------------------------------------------
  defp resolve_root() do
    case Process.get(@pd_root_key) do
      pid when is_pid(pid) ->
        if :ets.member(@roots_tab, pid) do
          pid
        else
          nil
        end

      _other ->
        cond do
          :ets.member(@roots_tab, self()) ->
            Process.put(@pd_root_key, self())
            self()

          true ->
            case Process.get(:"$ancestors") do
              list when is_list(list) ->
                case Enum.find(list, &:ets.member(@roots_tab, &1)) do
                  nil ->
                    nil

                  root ->
                    Process.put(@pd_root_key, root)
                    root
                end

              _ ->
                nil
            end
        end
    end
  end
end
