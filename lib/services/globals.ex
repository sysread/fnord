defmodule Services.Globals do
  @moduledoc """
  Drop-in-ish replacement for Application env that *shadows* values down a
  process tree. Think: dynamic scope via process ancestry.

  - `put_env/3` sets an override in the *current tree* (installing the caller as a root if needed).
  - `get_env/3` first checks the current tree's overrides, then falls back to `Application.get_env/3`.
  - `delete_env/2` removes the tree-local override.
  - `get_all_env/1` lists all overrides in the current tree, overlaying them on top of `Application.get_all_env/1` if the caller is the root.
  - `put_all_env/2` bulk-inserts multiple overrides for one or more apps in the current tree (installing the caller as a root if needed).
  - `install_root/0` explicitly installs the caller as a shadowing root (rarely needed; `put_env/3` auto-installs).
  - `current_root/0` returns the current shadowing root PID (or nil). Useful for debugging.
  - `explain/0` prints the current process tree and its overrides (for debugging).
  """

  use GenServer

  @pd_root_key :globals_root_pid
  @roots_tab :globals_roots
  @data_tab :globals_data

  @type app :: atom()
  @type key :: term()
  @type value :: term()

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)

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
    root = resolve_root()

    found =
      case root do
        nil ->
          Application.get_env(app, key, default)

        root when root == self() ->
          # We *are* the root: check overrides, else fall back directly
          case :ets.lookup(@data_tab, {root, app, key}) do
            [{{^root, ^app, ^key}, value}] -> value
            [] -> Application.get_env(app, key, default)
          end

        root ->
          # We're under a root: check overrides, else just return default
          case :ets.lookup(@data_tab, {root, app, key}) do
            [{{^root, ^app, ^key}, value}] -> value
            [] -> default
          end
      end

    found
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
  Bulk put multiple overrides for one or more apps in the current tree
  (installing the caller as a root if needed).
  """
  @spec put_all_env([{app(), [{key(), value()}]}], keyword()) :: :ok
  def put_all_env(app_kvs_list, _opts \\ [])

  def put_all_env(app_kvs_list, _opts) when is_list(app_kvs_list) do
    root = ensure_root!()

    Enum.each(app_kvs_list, fn
      {app, kvs} when is_atom(app) and is_list(kvs) ->
        Enum.each(kvs, fn {k, v} ->
          true = :ets.insert(@data_tab, {{root, app, k}, v})
        end)

      other ->
        raise ArgumentError,
              "put_all_env/2 expects [{app, keyword}] entries, got: #{inspect(other)}"
    end)

    :ok
  end

  def put_all_env(app, kvs) when is_atom(app) and is_list(kvs) do
    put_all_env([{app, kvs}], [])
  end

  @doc """
  Get all tree-local overrides for the given app, overlaying them on top of
  `Application.get_all_env/1` if the caller is the root.
  """
  @spec get_all_env(atom()) :: keyword()
  def get_all_env(app) do
    case resolve_root() do
      nil ->
        Application.get_all_env(app)

      root when root == self() ->
        # We *are* the root: overlay overrides on top of Application env
        # (overrides win).
        base = Application.get_all_env(app)

        root
        |> overrides_for(app)
        |> Enum.reduce(base, fn {k, v}, acc ->
          Keyword.put(acc, k, v)
        end)

      root ->
        # Descendant: show only overrides (matches your get_env/3 semantics)
        overrides_for(root, app) |> Enum.sort_by(&elem(&1, 0))
    end
  end

  @doc """
  Install the caller as a shadowing root explicitly (rarely needed; put_env/3
  auto-installs).
  """
  @spec install_root() :: :ok
  def install_root() do
    GenServer.call(__MODULE__, {:install_root, self()})
  end

  @doc """
  Return the current shadowing root PID (or nil). Useful for debugging.
  """
  @spec current_root() :: pid | nil
  def current_root(), do: resolve_root()

  def explain() do
    root = resolve_root()
    IO.puts("Globals process tree (root = #{inspect(root)})")
    do_explain(root, 0)
    :ok
  end

  defp do_explain(pid, depth) when is_pid(pid) do
    indent = String.duplicate("  ", depth)

    # Which apps/keys are set for this pid?
    entries =
      :ets.select(@data_tab, [
        {{{pid, :"$1", :"$2"}, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])

    if entries != [] do
      IO.puts("#{indent}- #{inspect(pid)}")

      Enum.each(entries, fn {app, key, val} ->
        IO.puts("#{indent}    #{inspect(app)}.#{inspect(key)} = #{inspect(val)}")
      end)
    else
      IO.puts("#{indent}- #{inspect(pid)} (no overrides)")
    end

    # Recurse into linked children
    case Process.info(pid, :links) do
      {:links, links} ->
        Enum.each(links, fn child ->
          if is_pid(child) and Process.alive?(child) do
            do_explain(child, depth + 1)
          end
        end)

      _ ->
        :ok
    end
  end

  # ----------------------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@roots_tab, [:named_table, :set, :public])
    :ets.new(@data_tab, [:named_table, :set, :public, :compressed, read_concurrency: true])
    {:ok, %{refs: %{}}}
  end

  @impl true
  def handle_call({:install_root, pid}, _from, s) do
    if :ets.member(@roots_tab, pid) do
      {:reply, :ok, s}
    else
      ref = Process.monitor(pid)
      :ets.insert(@roots_tab, {pid, true})

      # cache root in caller PD so descendants resolve quickly
      if self() == pid do
        Process.put(@pd_root_key, pid)
      end

      s = put_in(s.refs[ref], pid)
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
        :ets.select_delete(@data_tab, ms)

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

  @spec overrides_for(pid(), atom()) :: keyword()
  defp overrides_for(root, app) do
    # Robust and simple: match → map to {k,v}
    @data_tab
    |> :ets.match({{root, app, :"$1"}, :"$2"})
    |> Enum.map(fn [k, v] -> {k, v} end)
  end
end
