defmodule UI.Queue do
  @moduledoc """
  Priority queue for UI operations to ensure proper serialization of output and user interactions.

  ## What is a UI Context?

  A UI context is a logical grouping of related UI operations that should execute together
  without interruption from other UI operations. For example, a confirmation dialog that
  shows information, asks a question, and displays the result should all execute as one
  atomic unit.

  Each UI context has a unique token that allows UI operations to either:
  - Execute immediately (if called from within the same context)
  - Queue for later execution (if called from outside any context)

  ## Context Wrappers for Interactive UI

  Use these wrapper functions when calling interactive UI functions from contexts that
  could cause deadlocks:

  - `run_from_genserver/1` - For GenServer callbacks (starts fresh UI context)
  - `run_from_task/1` - For Task.async (preserves parent UI context)

  **Interactive UI functions that require wrapping:**
  - `UI.confirm/1`
  - `UI.choose/2` 
  - `UI.prompt/1`

  **GenServer example:**
      def handle_call(:confirm_delete, _from, state) do
        result = UI.Queue.run_from_genserver(fn ->
          UI.confirm("Delete this item?")
        end)
        {:reply, result, state}
      end

  **Task.async example:**
      task = Task.async(fn ->
        UI.Queue.run_from_task(fn ->
          UI.confirm("Process this item?")
        end)
      end)
      result = Task.await(task)

  Non-interactive UI functions (`UI.info/2`, `UI.error/2`, etc.) can be called directly.
  """

  use GenServer
  require Logger

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  # Normal output (fast-path if in interaction context)
  def puts(server \\ __MODULE__, io_device \\ :stdio, data, timeout \\ :infinity) do
    if in_ctx?(server) do
      exec({:puts, io_device, data})
    else
      GenServer.call(server, {:puts, io_device, data}, timeout)
    end
  end

  # Logger proxy (fast-path if in interaction context)
  def log(server \\ __MODULE__, level, chardata, md \\ [], timeout \\ :infinity) do
    if in_ctx?(server) do
      exec({:log, level, chardata, md})
    else
      GenServer.call(server, {:log, level, chardata, md}, timeout)
    end
  end

  # Interactive (priority). If already in context, run inline.
  def interact(server \\ __MODULE__, fun, timeout \\ :infinity) when is_function(fun, 0) do
    if in_ctx?(server) do
      exec({:interact, fun})
    else
      GenServer.call(server, {:interact, fun}, timeout)
    end
  end

  # ----------------------------------------------------------------------------
  # Context utilities for spawned processes
  # ----------------------------------------------------------------------------
  def interaction_token(server \\ __MODULE__) do
    Process.get(pd_key(server))
  end

  def bind(server \\ __MODULE__, token, fun) when is_function(fun, 0) do
    Process.put(pd_key(server), token)

    try do
      fun.()
    after
      Process.delete(pd_key(server))
    end
  end

  @doc """
  Wrapper for running interactive UI calls from GenServer callbacks.

  This **starts a fresh UI interaction context**, which prevents deadlocks when 
  GenServer callbacks need to make interactive UI calls that could send messages
  back to the same GenServer.

  Use this for interactive functions like `UI.confirm/1`, `UI.choose/2`, and `UI.prompt/1`
  when called from `handle_call/3`, `handle_cast/2`, or `handle_info/2`.

  ## Example
      def handle_call(:confirm_delete, _from, state) do
        result = UI.Queue.run_from_genserver(fn ->
          UI.confirm("Delete this item?")
        end)
        {:reply, result, state}
      end
  """
  def run_from_genserver(server \\ __MODULE__, fun) when is_function(fun, 0) do
    bind(server, make_ref(), fun)
  end

  @doc """
  Wrapper for running interactive UI calls from async tasks (Task.async).

  This **preserves the parent process's UI interaction context**, allowing async
  tasks to participate in the same UI interaction as their parent. This is essential
  when tasks need to make interactive UI calls as part of an ongoing user interaction.

  Use this when spawning tasks that might make interactive UI calls and you want
  them to be part of the current user interaction session.

  ## Example
      # In a function that's already in a UI interaction context
      task = Task.async(fn ->
        UI.Queue.run_from_task(fn ->
          # This UI call will be part of the parent's interaction
          UI.confirm("Process this item?")
        end)
      end)
      
      result = Task.await(task)
  """
  def run_from_task(server \\ __MODULE__, fun) when is_function(fun, 0) do
    parent_token = interaction_token(server)
    bind(server, parent_token, fun)
  end

  def spawn_bound(server \\ __MODULE__, fun) when is_function(fun, 0) do
    tok = interaction_token(server)
    spawn(fn -> bind(server, tok, fun) end)
  end

  # ----------------------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------------------
  @impl true
  def init(:ok) do
    state = %{busy: false, hq: :queue.new(), q: :queue.new()}
    {:ok, state}
  end

  # INTERACT
  @impl true
  def handle_call({:interact, fun}, from, %{busy: false} = st) do
    st = %{st | busy: true}
    result = exec({:interact, fun})
    GenServer.reply(from, result)
    {:noreply, drain(st)}
  end

  def handle_call({:interact, fun}, from, %{busy: true} = st) do
    {:noreply, enqueue(:hq, {from, {:interact, fun}}, st)}
  end

  # PUTS
  def handle_call({:puts, dev, data}, from, %{busy: false} = st) do
    st = %{st | busy: true}
    result = exec({:puts, dev, data})
    GenServer.reply(from, result)
    {:noreply, drain(st)}
  end

  def handle_call({:puts, dev, data}, from, %{busy: true} = st) do
    {:noreply, enqueue(:q, {from, {:puts, dev, data}}, st)}
  end

  # LOG
  def handle_call({:log, level, chardata, md}, from, %{busy: false} = st) do
    st = %{st | busy: true}
    result = exec({:log, level, chardata, md})
    GenServer.reply(from, result)
    {:noreply, drain(st)}
  end

  def handle_call({:log, level, chardata, md}, from, %{busy: true} = st) do
    {:noreply, enqueue(:q, {from, {:log, level, chardata, md}}, st)}
  end

  @impl true
  def handle_info(_msg, st), do: {:noreply, st}

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp enqueue(:hq, item, %{hq: q} = st), do: %{st | hq: :queue.in(item, q)}
  defp enqueue(:q, item, %{q: q} = st), do: %{st | q: :queue.in(item, q)}

  defp drain(%{busy: true} = st) do
    case take_next(st) do
      {:none, st2} ->
        %{st2 | busy: false}

      {{from, job}, st2} ->
        result = exec(job)
        GenServer.reply(from, result)
        drain(st2)
    end
  end

  defp take_next(%{hq: hq} = st) do
    case :queue.out(hq) do
      {{:value, item}, hq2} ->
        {item, %{st | hq: hq2}}

      {:empty, _} ->
        case :queue.out(st.q) do
          {{:value, item}, q2} -> {item, %{st | q: q2}}
          {:empty, _} -> {:none, st}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Execution with tokened interaction context
  # ----------------------------------------------------------------------------
  defp exec({:interact, fun}) do
    token = make_ref()
    # key by server pid
    put_token(self(), token)

    try do
      {:ok, fun.()}
    rescue
      e -> {:error, {e, __STACKTRACE__}}
    catch
      kind, val -> {:error, {kind, val}}
    after
      del_token(self())
    end
  end

  defp exec({:puts, dev, data}) do
    try do
      case dev do
        :stdio -> Owl.IO.puts(data)
        _ -> IO.puts(dev, data)
      end

      :ok
    rescue
      e -> {:error, {e, __STACKTRACE__}}
    end
  end

  defp exec({:log, level, chardata, md}) do
    try do
      Logger.log(level, chardata, md)
      :ok
    rescue
      e -> {:error, {e, __STACKTRACE__}}
    end
  end

  # ----------------------------------------------------------------------------
  # PD helpers (keyed by server pid)
  # ----------------------------------------------------------------------------
  defp to_pid(server) when is_pid(server), do: server

  defp to_pid(server) do
    case Process.whereis(server) do
      nil -> server
      pid -> pid
    end
  end

  defp pd_key(server), do: {:uiq_ctx, to_pid(server)}
  defp in_ctx?(server), do: Process.get(pd_key(server)) != nil
  defp put_token(server, token), do: Process.put(pd_key(server), token)
  defp del_token(server), do: Process.delete(pd_key(server))
end
