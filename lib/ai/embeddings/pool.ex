defmodule AI.Embeddings.Pool do
  @moduledoc """
  GenServer managing a long-lived embed.exs process in JSONL pool mode.

  Spawns the embedding script as an Erlang Port and communicates via
  line-delimited JSON on stdin/stdout. Each request gets a unique id;
  responses are matched back to waiting callers by id.

  The script handles its own concurrency internally (Task.Supervisor with
  bounded workers), so this GenServer is the single point of contact for
  the rest of the application.

  ## Lifecycle

  `ensure_started/1` is idempotent and the usual entry point for commands
  that need embeddings (`ask`, `index`, `search`, `memory`,
  `conversations`). It no-ops when the Indexer has been overridden for
  tests. A normal `GenServer.stop/1` or `shutdown/0` marks the pool as
  shutting down so the inevitable port-death messages that follow don't
  emit bogus "embed process died" warnings.

  On unexpected port death (crash, non-zero exit, monitor fired), the
  pool fails any in-flight callers with `{:error, :port_died}`, waits
  briefly, and respawns the port.

  ## Error shapes

  Callers of `embed/1` (and `AI.Embeddings.get/1`, which delegates here)
  should expect these error tuples:

    * `{:error, :pool_not_running}` - the pool GenServer is not alive.
      Call `ensure_started/1` first.
    * `{:error, :port_not_connected}` - a call arrived during the
      restart window after the port died but before the new one spawned.
      Retrying is usually fine.
    * `{:error, :port_died}` - the port died while a call was in flight.
    * `{:error, :timeout}` - embedding did not complete within the
      30-minute call timeout (sized to cover first-invocation cold boot).
    * `{:error, :shutting_down}` - the pool is terminating; the caller's
      request will not be processed.
    * `{:error, binary}` - structured error surfaced by embed.exs itself
      (e.g. missing text field, internal exception). The binary is a
      short description.

  ## Back-pressure

  The pool does not cap pending requests. Each embed call becomes a
  `GenServer.call` with a 30-minute timeout and gets queued in the
  `pending` map until embed.exs produces a matching response. In-flight
  concurrency on the embed.exs side is bounded by `:workers` (default
  `max(System.schedulers_online() - 2, 8)` - scales to the host, with an
  8-worker floor so small boxes still get reasonable throughput); callers
  beyond that wait on the port's stdin pipe.
  """

  use GenServer

  # Minimum worker count; also the default for hosts with <= 10 schedulers.
  # The default heuristic leaves 2 schedulers free so the BEAM + the rest of
  # the CLI (UI, HTTP pool, background indexers) don't starve while EXLA is
  # crunching.
  @min_workers 8

  # How long a caller will wait for an embedding result before timing out.
  #
  # The window has to cover first-invocation cold boot: after spawn_port/1
  # returns, the embed.exs process still has to run `Mix.install` (Bumblebee,
  # EXLA, Jason), compile the EXLA NIF, download the HuggingFace model
  # weights (~130MB), and JIT the inference graph before the first
  # embedding can be computed. On a cold laptop with a slow network that
  # sequence routinely runs 10-15 minutes. A post-install/upgrade user who
  # hit a 5-minute cap saw `{:error, :timeout}` before the model finished
  # downloading.
  #
  # Legitimate hangs are still caught quickly by the port monitor
  # (`handle_port_death/3`), so this bound only governs "request accepted,
  # no response yet" - in practice, only the first call of a cold process.
  @call_timeout :timer.minutes(30)

  # After the port dies, wait briefly before restarting to avoid tight loops
  # on persistent failures (missing elixir, broken EXLA, etc.).
  @restart_delay_ms 2_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the pool. Options:
    - :workers - number of concurrent embedding workers. Defaults to
      `max(System.schedulers_online() - 2, #{@min_workers})` so larger
      hosts scale up without starving the rest of the BEAM.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the worker count the pool will use when `:workers` isn't passed.
  Exposed for visibility (logging, debug); not used internally.
  """
  @spec default_workers() :: pos_integer
  def default_workers, do: max(System.schedulers_online() - 2, @min_workers)

  @doc """
  Idempotently ensures the pool is running for commands that produce
  embeddings (ask, index, search, memory, conversation search).

  No-ops when the configured Indexer has been overridden for testing
  (StubIndexer etc.); those paths never reach AI.Embeddings at all, and
  spawning a real embed.exs in a temp-dir test harness produces noise.
  """
  @spec ensure_started(keyword) :: :ok
  def ensure_started(opts \\ []) do
    if Indexer.impl() == Indexer do
      case start_link(opts) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          UI.warn("[Embeddings.Pool] Failed to start: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Embeds a text string, returning a 384-dimensional float vector.
  Blocks until the result arrives from the embed.exs process.

  See the module doc for the full list of possible error tuples.
  """
  @spec embed(String.t()) ::
          {:ok, [float()]}
          | {:error, :pool_not_running}
          | {:error, :port_not_connected}
          | {:error, :port_died}
          | {:error, :timeout}
          | {:error, :shutting_down}
          | {:error, binary}
  def embed(text) when is_binary(text) do
    GenServer.call(__MODULE__, {:embed, text}, @call_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :pool_not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Gracefully stops the pool, suppressing the warnings that would
  otherwise be triggered by the port-closed messages that follow.
  Idempotent; safe to call when the pool is not running.
  """
  @spec shutdown() :: :ok
  def shutdown do
    try do
      GenServer.stop(__MODULE__, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    workers = Keyword.get(opts, :workers) || default_workers()
    Process.flag(:trap_exit, true)

    state = %{
      port: nil,
      ref: nil,
      workers: workers,
      pending: %{},
      next_id: 0,
      buffer: "",
      # set by terminate/2 so death messages that race with intentional
      # shutdown don't emit "embed process died" warnings and don't
      # trigger a port respawn that will immediately be torn down.
      shutting_down?: false
    }

    {:ok, state, {:continue, :spawn}}
  end

  @impl GenServer
  def handle_continue(:spawn, state) do
    case spawn_port(state.workers) do
      {:ok, port, ref} ->
        {:noreply, %{state | port: port, ref: ref, buffer: ""}}

      {:error, reason} ->
        state = fail_all_pending(state, {:error, reason})
        {:stop, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:embed, text}, from, %{port: port} = state) when is_port(port) do
    id = state.next_id
    id_str = Integer.to_string(id)

    payload = SafeJson.encode!(%{"id" => id_str, "text" => text})
    Port.command(port, payload <> "\n")

    pending = Map.put(state.pending, id_str, from)
    {:noreply, %{state | pending: pending, next_id: id + 1}}
  end

  def handle_call({:embed, _text}, _from, state) do
    {:reply, {:error, :port_not_connected}, state}
  end

  # Port sends data in chunks; buffer until we have complete lines.
  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {lines, rest} = split_lines(buffer)

    state =
      Enum.reduce(lines, %{state | buffer: rest}, fn line, acc ->
        handle_response_line(line, acc)
      end)

    {:noreply, state}
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    handle_port_death(state, "closed", force_warn: false)
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Non-zero exit is anomalous even without pending callers; status=0
    # on shutdown is quiet unless someone was mid-request.
    force? = status != 0
    handle_port_death(state, "exit_status=#{status}", force_warn: force?)
  end

  def handle_info({:DOWN, ref, :port, _port, reason}, %{ref: ref} = state) do
    handle_port_death(state, "DOWN #{inspect(reason)}", force_warn: false)
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    handle_port_death(state, "EXIT #{inspect(reason)}", force_warn: false)
  end

  # Restart timer fired
  def handle_info(:restart_port, %{shutting_down?: true} = state) do
    {:noreply, state}
  end

  def handle_info(:restart_port, state) do
    {:noreply, state, {:continue, :spawn}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: port} = state) do
    # Flip the flag first so any port-death messages already in flight (or
    # queued by the Port.close below) see shutting_down? and skip warnings /
    # respawn.
    state = %{state | shutting_down?: true}

    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end

    fail_all_pending(state, {:error, :shutting_down})
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp spawn_port(workers) do
    AI.Embeddings.Script.ensure_scripts!()
    wrapper = AI.Embeddings.Script.wrapper_path()

    case System.find_executable("bash") do
      nil ->
        {:error, "bash not found"}

      bash ->
        port =
          Port.open(
            {:spawn_executable, bash},
            [
              :binary,
              :exit_status,
              args: [wrapper, "-n", Integer.to_string(workers)]
            ]
          )

        ref = Port.monitor(port)
        {:ok, port, ref}
    end
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [only] -> {[], only}
      parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
    end
  end

  defp handle_response_line("", state), do: state

  defp handle_response_line(line, state) do
    case SafeJson.decode(line) do
      {:ok, %{"id" => id, "embedding" => embedding}} when is_list(embedding) ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            UI.warn("[Embeddings.Pool] received response for unknown id: #{id}")
            state

          {from, pending} ->
            GenServer.reply(from, {:ok, embedding})
            %{state | pending: pending}
        end

      {:ok, %{"id" => id, "error" => error}} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            state

          {from, pending} ->
            GenServer.reply(from, {:error, error})
            %{state | pending: pending}
        end

      {:ok, %{"error" => error}} ->
        UI.warn("[Embeddings.Pool] protocol error from embed process: #{error}")
        state

      {:error, _} ->
        UI.warn(
          "[Embeddings.Pool] unparseable output from embed process: #{String.slice(line, 0, 120)}"
        )

        state
    end
  end

  # Central handler for every flavor of port-death message. Suppresses the
  # warning and skips the respawn during intentional shutdown; otherwise
  # warns (unconditionally when `force_warn: true` or when there was
  # in-flight work that just got killed), fails pending callers, and
  # schedules a restart.
  defp handle_port_death(%{shutting_down?: true} = state, _kind, _opts) do
    state = fail_all_pending(state, {:error, :shutting_down})
    {:noreply, %{state | port: nil, ref: nil, buffer: ""}}
  end

  defp handle_port_death(state, kind, opts) do
    force? = Keyword.get(opts, :force_warn, false)

    if force? or map_size(state.pending) > 0 do
      warn_death(state, kind)
    end

    state = fail_all_pending(state, {:error, :port_died})
    Process.send_after(self(), :restart_port, @restart_delay_ms)
    {:noreply, %{state | port: nil, ref: nil, buffer: ""}}
  end

  defp warn_death(state, kind) do
    tail = state.buffer |> String.slice(-200, 200)

    UI.warn(
      "[Embeddings.Pool] embed process died (#{kind}); " <>
        "#{map_size(state.pending)} in-flight request(s) will fail; " <>
        "buffer tail=#{inspect(tail)}"
    )
  end

  defp fail_all_pending(state, error) do
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, error)
    end)

    %{state | pending: %{}}
  end
end
