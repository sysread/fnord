defmodule Services.MemoryIndexer do
  @moduledoc """
  Background service that promotes session-scoped memories to long-term
  (project/global) storage. Independently scans conversations for
  unprocessed session memories, processes one conversation at a time via
  the Memory.Indexer agent, and applies the resulting actions.

  The service is self-driven: on startup it begins scanning for work. After
  processing a conversation, it scans again. When no unprocessed memories
  remain, it goes idle. External callers can nudge it via `scan/0` if they
  know new work is available (e.g. after saving a conversation).

  Public API:
  - start_link/1
  - scan/0         -- nudge the service to look for work
  - process_sync/1 -- test-only synchronous processing
  - status/0
  """

  use GenServer

  @cleanup_message :cleanup_orphan_memory_locks
  @lock_cleanup_interval_ms :timer.minutes(5)
  @orphan_lock_stale_ms :timer.minutes(2)
  @lock_owner_file "owner"
  @lt_memory_tool %{"long_term_memory_tool" => AI.Tools.LongTermMemory}

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Nudge the service to scan for unprocessed conversations"
  def scan do
    GenServer.cast(__MODULE__, :scan)
  end

  @doc "Process a conversation synchronously; returns :ok | {:error, term()}"
  def process_sync(convo) do
    GenServer.call(__MODULE__, {:process_sync, convo}, :infinity)
  end

  @doc "Get status: whether a task is currently running"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --------------------------------------------------------------------------
  # GenServer callbacks
  # --------------------------------------------------------------------------
  def init(opts) do
    {:ok, sup} = Task.Supervisor.start_link()
    auto_scan = Keyword.get(opts, :auto_scan, true)
    :ok = safe_cleanup_orphan_memory_locks()
    state = %{task: nil, sup: sup, cleanup_timer: safe_schedule_lock_cleanup()}

    case auto_scan do
      true -> {:ok, state, {:continue, :scan}}
      false -> {:ok, state}
    end
  end

  # Scan for the next conversation with unprocessed memories and spawn a
  # background task to process it. If already busy or nothing found, no-op.
  def handle_continue(:scan, %{task: nil, sup: sup} = state) do
    case find_next_conversation() do
      nil ->
        {:noreply, state}

      convo ->
        task = spawn_processing_task(sup, convo)
        {:noreply, %{state | task: task}}
    end
  end

  def handle_continue(:scan, state), do: {:noreply, state}

  def handle_cast(:scan, %{task: nil} = state) do
    {:noreply, state, {:continue, :scan}}
  end

  def handle_cast(:scan, state), do: {:noreply, state}

  # Compile-time environment gate. process_sync blocks the GenServer for the
  # entire LLM round-trip, which is fine for deterministic test execution but
  # would deadlock in production. Rather than trusting callers to know this,
  # we simply don't compile the working implementation outside of test. Yes,
  # this is a compile-time conditional in application code. We are not proud,
  # but we are correct.
  if Mix.env() == :test do
    def handle_call({:process_sync, convo}, _from, state) do
      HttpPool.set(:ai_memory)
      res = do_process_conversation(convo)
      {:reply, res, state}
    end
  else
    def handle_call({:process_sync, _convo}, _from, _state) do
      raise "process_sync is only available in the test environment"
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, %{busy: state.task != nil}, state}
  end

  # Task completed: clear state and scan for more work.
  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil}, {:continue, :scan}}
  end

  # Task crashed: clear state and scan for more work.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | task: nil}, {:continue, :scan}}
  end

  def handle_info(@cleanup_message, state) do
    :ok = safe_cleanup_orphan_memory_locks()
    {:noreply, %{state | cleanup_timer: safe_schedule_lock_cleanup()}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # On shutdown, cancel maintenance work and kill any in-flight task so the
  # BEAM can exit promptly.
  def terminate(_reason, state) do
    :ok = cancel_lock_cleanup(state.cleanup_timer)
    :ok = stop_processing_task(state.task)
  end

  # --------------------------------------------------------------------------
  # Scanning
  # --------------------------------------------------------------------------

  # Walk conversations oldest-first, return the first that has unprocessed
  # session memories. Skips the currently active conversation.
  defp find_next_conversation do
    with {:ok, project} <- Store.get_project() do
      current_id = current_conversation_id()

      project
      |> Store.Project.Conversation.list()
      |> Enum.reject(fn convo -> convo.id == current_id end)
      |> Enum.find(&has_unprocessed_memories?/1)
    else
      _ -> nil
    end
  end

  defp current_conversation_id do
    case Services.Globals.get_env(:fnord, :current_conversation, nil) do
      nil -> nil
      pid -> Services.Conversation.get_id(pid)
    end
  end

  defp has_unprocessed_memories?(convo) do
    case Store.Project.Conversation.read(convo) do
      {:ok, data} -> find_unprocessed_memories(data) != []
      _ -> false
    end
  end

  # --------------------------------------------------------------------------
  # Task spawning
  # --------------------------------------------------------------------------

  # Spawn the processing task without linking to the GenServer. We use
  # Task.Supervisor.async_nolink so the GenServer is not dragged down if
  # the task crashes, and more importantly, so the BEAM can shut down
  # cleanly without waiting for in-flight LLM calls to complete.
  defp spawn_processing_task(sup, convo) do
    root = Services.Globals.current_root()

    Task.Supervisor.async_nolink(sup, fn ->
      if root, do: Process.put(:globals_root_pid, root)
      HttpPool.set(:ai_memory)
      do_process_conversation(convo)
    end)
  end

  # --------------------------------------------------------------------------
  # Conversation processing
  # --------------------------------------------------------------------------
  @spec do_process_conversation(any()) :: :ok | {:error, any()}
  defp do_process_conversation(convo) do
    process_conversation(convo)
  rescue
    e ->
      UI.debug("memory_indexer", "Worker crashed: #{Exception.message(e)}")
      {:error, e}
  end

  defp process_conversation(conversation) do
    with {:ok, data} <- Store.Project.Conversation.read(conversation),
         session_mems when session_mems != [] <- find_unprocessed_memories(data),
         {:ok, payload} <- build_indexer_payload(data, session_mems),
         {:ok, response} <- invoke_indexer_agent(payload),
         {:ok, decoded} <- parse_indexer_response(response),
         :ok <- validate_indexer_response(decoded) do
      apply_actions_and_mark(conversation, decoded)
    else
      [] -> :ok
      _ -> :ok
    end
  rescue
    e ->
      UI.debug("memory_indexer", "Processing failed: #{Exception.message(e)}")
      :ok
  end

  # --------------------------------------------------------------------------
  # Conversation processing helpers
  # --------------------------------------------------------------------------

  # Filter session memories that haven't been processed yet.
  defp find_unprocessed_memories(data) do
    data
    |> Map.get(:memory, [])
    |> Enum.filter(fn
      %Memory{scope: :session} = m -> is_nil(m.index_status) or m.index_status == :new
      _ -> false
    end)
  end

  # For each session memory, retrieve up to 5 matching global and 5 matching
  # project memories as candidates for merge/dedup/correction decisions.
  defp build_indexer_payload(data, session_mems) do
    memories_with_candidates = Enum.map(session_mems, &enrich_with_candidates/1)

    payload = %{
      conversation_summary: summarize_conversation(data.messages),
      memories: memories_with_candidates
    }

    {:ok, SafeJson.encode!(payload)}
  end

  defp enrich_with_candidates(mem) do
    %{
      title: mem.title,
      content: mem.content,
      topics: mem.topics,
      global_candidates: recall_candidates(mem.content, "global"),
      project_candidates: recall_candidates(mem.content, "project")
    }
  end

  defp recall_candidates(query, scope) do
    case AI.Tools.LongTermMemory.call(%{
           "action" => "recall",
           "query" => query,
           "search_type" => "project_global",
           "limit" => 5,
           "scope" => scope
         }) do
      {:ok, res} -> res
      {:error, _} -> []
    end
  end

  defp invoke_indexer_agent(json_payload) do
    AI.Agent.Memory.Indexer
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{payload: json_payload})
  end

  defp parse_indexer_response(response) do
    case SafeJson.decode(response) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp validate_indexer_response(%{"actions" => actions, "processed" => processed} = decoded) do
    status_updates = Map.get(decoded, "status_updates", %{})

    cond do
      not is_list(actions) ->
        {:error, "actions must be a list"}

      not is_list(processed) ->
        {:error, "processed must be a list"}

      not is_map(status_updates) ->
        {:error, "status_updates must be a map"}

      not Enum.all?(processed, &is_binary/1) ->
        {:error, "processed must be list of strings"}

      not Enum.all?(actions, &valid_action?/1) ->
        {:error, "invalid action object in actions"}

      true ->
        :ok
    end
  end

  defp validate_indexer_response(_), do: {:error, "missing actions or processed keys"}

  defp valid_action?(%{"action" => a, "target" => %{"scope" => _s, "title" => _t}})
       when a in ["add", "replace", "delete"],
       do: true

  defp valid_action?(_), do: false

  # --------------------------------------------------------------------------
  # Apply actions and mark session memories as processed
  # --------------------------------------------------------------------------
  defp apply_actions_and_mark(conversation, decoded) do
    actions = Map.get(decoded, "actions", [])
    processed = Map.get(decoded, "processed", [])
    status_updates = Map.get(decoded, "status_updates", %{})

    FileLock.with_lock(conversation.store_path, fn ->
      {:ok, fresh} = Store.Project.Conversation.read(conversation)

      Enum.each(actions, &apply_action/1)

      fresh
      |> Map.put(:memory, mark_processed(fresh.memory, processed, status_updates))
      |> then(&Store.Project.Conversation.write(conversation, &1))
    end)

    :ok
  end

  # First pass: mark all processed session memories as :analyzed.
  # Second pass: override with explicit status_updates from the agent.
  defp mark_processed(memories, processed, status_updates) do
    memories
    |> Enum.map(fn
      %Memory{scope: :session, title: title} = m ->
        if title in processed, do: %{m | index_status: :analyzed}, else: m

      other ->
        other
    end)
    |> Enum.map(fn
      %Memory{scope: :session, title: title} = m ->
        maybe_apply_status_update(m, Map.get(status_updates, title))

      other ->
        other
    end)
  end

  @valid_statuses ["analyzed", "rejected", "incorporated", "merged"]
  defp maybe_apply_status_update(mem, status) when status in @valid_statuses do
    %{mem | index_status: String.to_existing_atom(status)}
  end

  defp maybe_apply_status_update(mem, _), do: mem

  # --------------------------------------------------------------------------
  # Action dispatch
  # --------------------------------------------------------------------------
  defp apply_action(%{"action" => "add", "target" => target, "content" => content}) do
    call_lt_memory("remember", target, content)
  end

  defp apply_action(%{"action" => "replace", "target" => target, "content" => content}) do
    call_lt_memory("update", target, content)
  end

  defp apply_action(%{"action" => "delete", "target" => target}) do
    call_lt_memory("forget", target, nil)
  end

  defp apply_action(_), do: :ok

  defp call_lt_memory(action, %{"scope" => scope, "title" => title}, content) do
    args =
      %{"action" => action, "scope" => scope, "title" => title}
      |> maybe_put_content(content)

    case AI.Tools.perform_tool_call("long_term_memory_tool", args, @lt_memory_tool) do
      {:ok, _} -> :ok
      {:error, reason} -> UI.debug("memory_indexer", "#{action} failed: #{inspect(reason)}")
    end

    :ok
  end

  defp maybe_put_content(args, nil), do: args
  defp maybe_put_content(args, content), do: Map.put(args, "content", content)

  # --------------------------------------------------------------------------
  # Orphaned memory lock cleanup
  # --------------------------------------------------------------------------

  @doc """
  Cleans up abandoned stale per-memory lock directories whose target memory
  files no longer exist.

  FileLock creates a `*.json.lock` directory before the target `*.json` file may
  exist and records the owning local pid in an `owner` file inside that lock
  directory. This maintenance path intentionally mirrors that lifecycle: it only
  inspects `*.json.lock` entries under the project and global memory storage
  roots, leaves allocation locks and unrelated store locks alone, and only
  removes a lock when the target file is missing, the lock age is strictly
  greater than the stale threshold, and no live local owner pid can be found.
  """
  @spec cleanup_orphan_memory_locks() :: :ok
  def cleanup_orphan_memory_locks do
    memory_storage_roots()
    |> Enum.flat_map(&memory_lock_dirs/1)
    |> Enum.filter(&orphaned_memory_lock?/1)
    |> Enum.each(&File.rm_rf/1)

    :ok
  end

  @spec safe_cleanup_orphan_memory_locks() :: :ok
  defp safe_cleanup_orphan_memory_locks do
    cleanup_orphan_memory_locks()
  rescue
    e ->
      UI.debug("memory_indexer", "Lock cleanup skipped: #{Exception.message(e)}")
      :ok
  end

  @spec safe_schedule_lock_cleanup() :: reference() | nil
  defp safe_schedule_lock_cleanup do
    schedule_lock_cleanup()
  rescue
    e ->
      UI.debug("memory_indexer", "Lock cleanup timer not scheduled: #{Exception.message(e)}")
      nil
  end

  @spec schedule_lock_cleanup() :: reference()
  defp schedule_lock_cleanup do
    Process.send_after(self(), @cleanup_message, @lock_cleanup_interval_ms)
  end

  @spec cancel_lock_cleanup(reference() | nil) :: :ok
  defp cancel_lock_cleanup(nil), do: :ok

  defp cancel_lock_cleanup(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  @spec stop_processing_task(Task.t() | nil) :: :ok
  defp stop_processing_task(nil), do: :ok

  defp stop_processing_task(%Task{pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  defp stop_processing_task(%Task{}), do: :ok

  @spec memory_storage_roots() :: [String.t()]
  defp memory_storage_roots do
    [global_memory_storage_root(), project_memory_storage_root()]
    |> Enum.reject(&is_nil/1)
  end

  @spec global_memory_storage_root() :: String.t()
  defp global_memory_storage_root do
    Path.join(Store.store_home(), "memory")
  end

  @spec project_memory_storage_root() :: String.t() | nil
  defp project_memory_storage_root do
    case Store.get_project() do
      {:ok, project} -> Path.join(project.store_path, "memory")
      _ -> nil
    end
  end

  @spec memory_lock_dirs(String.t()) :: [String.t()]
  defp memory_lock_dirs(storage_root) do
    storage_root
    |> Path.join("*.json.lock")
    |> Path.wildcard()
  end

  @spec orphaned_memory_lock?(String.t()) :: boolean()
  defp orphaned_memory_lock?(lock_dir) do
    case {memory_file_missing?(lock_dir), stale_lock_dir?(lock_dir), live_lock_owner?(lock_dir)} do
      {true, true, false} -> true
      _ -> false
    end
  end

  @spec memory_file_missing?(String.t()) :: boolean()
  defp memory_file_missing?(lock_dir) do
    not File.exists?(memory_file_for_lock(lock_dir))
  end

  @spec memory_file_for_lock(String.t()) :: String.t()
  defp memory_file_for_lock(lock_dir) do
    Path.rootname(lock_dir, ".lock")
  end

  @spec stale_lock_dir?(String.t()) :: boolean()
  defp stale_lock_dir?(lock_dir) do
    case lock_dir_age_ms(lock_dir) do
      {:ok, age_ms} when age_ms > @orphan_lock_stale_ms -> true
      _ -> false
    end
  end

  @spec lock_dir_age_ms(String.t()) :: {:ok, non_neg_integer()} | :error
  defp lock_dir_age_ms(lock_dir) do
    case File.stat(lock_dir, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        now = System.system_time(:second)
        {:ok, max(0, (now - mtime) * 1_000)}

      _ ->
        :error
    end
  end

  @spec live_lock_owner?(String.t()) :: boolean()
  defp live_lock_owner?(lock_dir) do
    case lock_owner_pid(lock_dir) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  @spec lock_owner_pid(String.t()) :: {:ok, pid()} | :error
  defp lock_owner_pid(lock_dir) do
    case read_lock_owner(lock_dir) do
      {:ok, owner} -> parse_lock_owner_pid(owner)
      :error -> :error
    end
  end

  @spec read_lock_owner(String.t()) :: {:ok, String.t()} | :error
  defp read_lock_owner(lock_dir) do
    lock_dir
    |> lock_owner_file()
    |> File.read()
    |> normalize_lock_owner_contents()
  end

  @spec lock_owner_file(String.t()) :: String.t()
  defp lock_owner_file(lock_dir) do
    Path.join(lock_dir, @lock_owner_file)
  end

  @spec normalize_lock_owner_contents({:ok, binary()} | {:error, any()}) ::
          {:ok, String.t()} | :error
  defp normalize_lock_owner_contents({:ok, owner}) do
    case String.trim(owner) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_lock_owner_contents({:error, _}), do: :error

  @spec parse_lock_owner_pid(String.t()) :: {:ok, pid()} | :error
  defp parse_lock_owner_pid(owner) do
    case owner_pid_line(owner) do
      {:ok, pid_line} -> parse_pid_line(pid_line)
      :error -> :error
    end
  end

  @spec owner_pid_line(String.t()) :: {:ok, String.t()} | :error
  defp owner_pid_line(owner) do
    owner
    |> String.split("\n", trim: true)
    |> Enum.find_value(:error, fn line ->
      case String.trim(line) do
        "pid: " <> pid_text -> {:ok, pid_text}
        _ -> false
      end
    end)
  end

  @spec parse_pid_line(String.t()) :: {:ok, pid()} | :error
  defp parse_pid_line(pid_line) do
    pid_line
    |> String.to_charlist()
    |> :erlang.list_to_pid()
    |> normalize_lock_owner_pid()
  catch
    :error, _ -> :error
  end

  @spec normalize_lock_owner_pid(pid()) :: {:ok, pid()}
  defp normalize_lock_owner_pid(pid) when is_pid(pid), do: {:ok, pid}

  # --------------------------------------------------------------------------
  # Conversation summarization
  # --------------------------------------------------------------------------
  def summarize_conversation(messages) when is_list(messages) do
    user = first_user_message(messages)
    assistant = last_assistant_message(messages)

    case {user, assistant} do
      {"", ""} -> ""
      {u, ""} -> "User: " <> u
      {"", a} -> "Assistant: " <> a
      {u, a} -> "User: " <> u <> " \nAssistant: " <> a
    end
  end

  def summarize_conversation(_), do: ""

  defp first_user_message(messages) do
    messages
    |> Enum.find(fn
      %{role: "user"} -> true
      _ -> false
    end)
    |> extract_content()
  end

  defp last_assistant_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn
      %{role: "assistant", content: c} when is_binary(c) ->
        not String.starts_with?(c, "<think>")

      _ ->
        false
    end)
    |> extract_content()
  end

  defp extract_content(%{content: c}), do: String.slice(c, 0, 400)
  defp extract_content(_), do: ""
end
