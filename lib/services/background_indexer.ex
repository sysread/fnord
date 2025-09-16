defmodule Services.BackgroundIndexer do
  @moduledoc """
  ## Overview

  The BackgroundIndexer is a silent, cancellable GenServer that indexes project files
  one at a time. It generates per-file derivatives (summary, outline, embeddings)
  and saves them to the project store.

  This module is intentionally designed to be both:
  - sequential (one file at a time) for predictability and resource control
  - promptly cancellable so the parent command (e.g., `ask`) can stop it immediately

  ## Strategy (literate walkthrough)

  - We do not pre-queue a large list of files. Instead, we:
    1) Optionally accept a small explicit `files_queue` from the caller (mainly used by tests)
    2) Otherwise fetch exactly one stale entry dynamically between tasks
  - Each file is processed in a linked Task so the GenServer stays responsive
  - We monitor the Task and, when it finishes, we schedule processing of the next file
  - If there is no next file, we stop the server with `:normal`
  - On shutdown, we kill any in-flight Task to guarantee prompt cancellation

  ## Lifecycle checkpoints

  - `init/1`: set per-process HTTP pool, determine project & initial files_queue, prime state
  - `handle_continue(:process_next)`: run the state machine to start the next Task or stop
  - `handle_info({:DOWN, ...})`: clear task state and schedule the next step
  - `terminate/2`: kill in-flight Task and clear HttpPool override

  ## Why one-at-a-time?

  - Prevents overwhelming APIs (summaries, outlines, embeddings)
  - Simplifies cancellation and error isolation
  - Ensures the background indexer does not keep running long after `ask` completes
  """

  use GenServer,
    # Do not restart if it crashes; it should stop when done
    restart: :temporary

  @spec start_link(
          opts :: [
            {:project, Store.Project.t()}
            | {:files, [Store.Project.Entry.t()]}
          ]
        ) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stop the BackgroundIndexer GenServer safely.
  This function is idempotent, swallows exits, and accepts non-pid values.
  Always returns :ok.
  """
  @spec stop(pid() | any()) :: :ok
  def stop(pid) when is_pid(pid) do
    # Attempt to stop the GenServer normally with a finite timeout.
    # Catch any exit (normal, noproc, timeout) to ensure safe, idempotent behavior.
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _reason ->
        :ok
    end
  end

  # Accept any other values (nil, atom, etc.) and no-op.
  def stop(_), do: :ok

  @doc """
  init/1 sets up the GenServer state, performing the following steps:
  1. Configure HttpPool for AI indexer requests (efficient, reusable connections)
  2. Determine `project` context from opts or Store.get_project/0
  3. Build `files_queue` from opts (if provided) or default to []
  4. Initialize state and immediately continue to :process_next
  """
  @impl true
  def init(opts) do
    # Configure the HTTP connection pool for downstream embedding and summary
    # API calls.
    HttpPool.set(:ai_indexer)

    project =
      case Keyword.get(opts, :project) do
        %Store.Project{} = prj ->
          prj

        _ ->
          case Store.get_project() do
            {:ok, prj} -> prj
            _ -> nil
          end
      end

    files_queue =
      case Keyword.get(opts, :files) do
        list when is_list(list) -> list
        _ -> []
      end

    state = %{
      project: project,
      impl: Indexer.impl(),
      files_queue: files_queue,
      task: nil,
      mon_ref: nil
    }

    {:ok, state, {:continue, :process_next}}
  end

  # ----------------------------------------------------------------------------
  # State machine for processing work
  # ----------------------------------------------------------------------------

  @doc """
  handle_continue(:process_next) operates in these modes:
  1) If a Task is already running, do nothing and wait for :DOWN
  2) If files_queue has entries, pop one and start a Task to process it
  3) If files_queue is empty but we have a project, fetch one stale entry
     and start a Task for it; if none remain, stop normally
  4) If there is no project and no files, stop normally
  """
  @impl true
  def handle_continue(:process_next, %{task: pid} = state)
      when is_pid(pid) do
    # A Task is already in-flight; we resume when it completes (:DOWN)
    {:noreply, state}
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, files_queue: [entry | rest]} = state) do
    # Start per-file work in a linked Task so the GenServer stays responsive
    {:ok, task_pid} = Task.start_link(fn -> safe_process(entry, state.impl, state.project) end)

    # Monitor the Task to receive a :DOWN message on completion
    mon_ref = Process.monitor(task_pid)
    new_state = %{state | task: task_pid, mon_ref: mon_ref, files_queue: rest}

    # We only schedule the next step when the Task completes
    {:noreply, new_state}
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, files_queue: [], project: project} = state)
      when not is_nil(project) do
    case next_stale_entry(project) do
      nil ->
        # No work remains; stop normally
        {:stop, :normal, state}

      entry ->
        {:ok, task_pid} =
          Task.start_link(fn -> safe_process(entry, state.impl, state.project) end)

        mon_ref = Process.monitor(task_pid)
        new_state = %{state | task: task_pid, mon_ref: mon_ref}
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, files_queue: [], project: nil} = state) do
    # No project and no queued files: nothing to do; stop normally
    {:stop, :normal, state}
  end

  @doc """
  When a monitored Task completes, we receive a :DOWN message.
  We clear the task state and trigger the next file via {:continue, :process_next}.
  This guarantees one-at-a-time processing and ensures prompt stop semantics.
  """
  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{mon_ref: ref, task: pid} = state) do
    new_state = %{state | task: nil, mon_ref: nil}
    {:noreply, new_state, {:continue, :process_next}}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore any other messages
    {:noreply, state}
  end

  @doc """
  terminate/2 ensures prompt cancellation and cleanup:
  - Kills any in-flight Task to stop work immediately
  - Clears the HttpPool override for this process
  """
  @impl true
  def terminate(_reason, state) do
    case state do
      %{task: pid} when is_pid(pid) -> Process.exit(pid, :kill)
      _ -> :ok
    end

    HttpPool.clear()
    :ok
  end

  # ----------------------------------------------------------------------------
  # Safely process a single entry: read, derive, and save.
  #
  # Steps:
  #   1) Read the source file (falls back to empty string on read errors)
  #   2) Generate summary and outline
  #   3) Create an embedding input from [summary, outline, content]
  #   4) Generate embeddings and persist to store
  #
  # Resilience:
  #   - Wrapped in try/rescue to isolate per-file failures
  #   - Logs end-of-step via UI without blocking main flow
  # ----------------------------------------------------------------------------
  defp safe_process(entry, impl, _project) do
    try do
      content =
        case Store.Project.Entry.read_source_file(entry) do
          {:ok, c} -> c
          _ -> ""
        end

      path = entry.file

      with {:ok, summary} = impl.get_summary(path, content),
           {:ok, outline} = impl.get_outline(path, content),
           embed_str = [summary, outline, content] |> Enum.join("\n\n"),
           {:ok, embeddings} = impl.get_embeddings(embed_str) do
        Store.Project.Entry.save(entry, summary, outline, embeddings)
        UI.end_step("Reindexed", entry.file)
      end
    rescue
      _ -> :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Fetch only one stale entry at a time rather than pre-queuing all of them to:
  #   1) Always pick up newly stale entries generated during ongoing processing
  #   2) Limit memory/overhead by keeping the queue minimal
  #   3) Avoid processing outdated entries if project state changes mid-run
  # ----------------------------------------------------------------------------
  @spec next_stale_entry(Store.Project.t()) :: Store.Project.Entry.t() | nil
  defp next_stale_entry(project) do
    project
    |> Store.Project.index_status()
    |> Map.get(:stale, [])
    |> List.first()
  end
end
