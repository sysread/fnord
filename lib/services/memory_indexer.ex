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
  require Logger

  @cleanup_message :cleanup_orphan_memory_locks
  @lock_cleanup_interval_ms :timer.minutes(5)
  @orphan_lock_stale_ms :timer.minutes(2)
  @lock_owner_file "owner"
  @lt_memory_tool %{"long_term_memory_tool" => AI.Tools.LongTermMemory}

  @deep_sleep_passes 3
  @deep_sleep_min_score 0.5

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
    state = %{task: nil, sup: sup, cleanup_timer: safe_schedule_lock_cleanup(), skip_ids: %{}}
    Logger.debug("[memory_indexer] started (auto_scan=#{auto_scan})")

    case auto_scan do
      true -> {:ok, state, {:continue, :scan}}
      false -> {:ok, state}
    end
  end

  # Scan for the next conversation with unprocessed memories and spawn a
  # background task to process it. When the queue empties, transition to deep
  # sleep (once per process lifetime). If already busy or nothing found, no-op.
  def handle_continue(:scan, %{task: nil, sup: sup} = state) do
    case find_next_conversation(state.skip_ids) do
      {nil, skip_ids} ->
        Logger.debug("[memory_indexer] queue empty - transitioning to deep sleep")
        UI.debug("Dozing", "Dreaming of electric sheep")
        {:noreply, %{state | skip_ids: skip_ids}, {:continue, :deep_sleep}}

      {convo, skip_ids} ->
        Logger.debug("[memory_indexer] processing conversation #{convo.id}")
        task = spawn_processing_task(sup, convo)
        {:noreply, %{state | task: task, skip_ids: skip_ids}}
    end
  end

  def handle_continue(:scan, state), do: {:noreply, state}

  # Deep sleep: consolidate similar memories within each scope. Runs at most
  # once per process lifetime, gated by Services.Once, after light sleep
  # exhausts the pending session memory queue.
  def handle_continue(:deep_sleep, %{task: nil, sup: sup} = state) do
    case Services.Once.set(:deep_sleep) do
      true ->
        Logger.debug("[memory_indexer] entering deep sleep")
        UI.debug("REM", "Nightswimming deserves a quiet night -- REM")
        task = spawn_deep_sleep_task(sup)
        {:noreply, %{state | task: task}}

      false ->
        Logger.debug("[memory_indexer] deep sleep already ran this session - idle")
        {:noreply, state}
    end
  end

  def handle_continue(:deep_sleep, state), do: {:noreply, state}

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
    Logger.debug("[memory_indexer] task done - scanning for more work")
    {:noreply, %{state | task: nil}, {:continue, :scan}}
  end

  # Task crashed: clear state and scan for more work.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.debug("[memory_indexer] task crashed - scanning for more work")
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
  # session memories. Skips the currently active conversation and any
  # conversations that previously failed to read (corrupt files).
  defp find_next_conversation(skip_ids) do
    with {:ok, project} <- Store.get_project() do
      current_id = current_conversation_id()

      project
      |> Store.Project.Conversation.list()
      |> Enum.reject(fn convo ->
        convo.id == current_id or Map.has_key?(skip_ids, convo.id)
      end)
      |> Enum.reduce_while({nil, skip_ids}, fn convo, {_match, skips} ->
        case has_unprocessed_memories?(convo) do
          true -> {:halt, {convo, skips}}
          false -> {:cont, {nil, skips}}
          :error -> {:cont, {nil, Map.put(skips, convo.id, true)}}
        end
      end)
    else
      _ -> {nil, skip_ids}
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
      {:error, {:corrupt_conversation, _}} -> :error
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

  defp spawn_deep_sleep_task(sup) do
    root = Services.Globals.current_root()

    Task.Supervisor.async_nolink(sup, fn ->
      if root, do: Process.put(:globals_root_pid, root)
      HttpPool.set(:ai_memory)
      run_deep_sleep()
    end)
  end

  # --------------------------------------------------------------------------
  # Deep sleep: same-scope memory deduplication
  # --------------------------------------------------------------------------

  defp run_deep_sleep do
    Logger.debug("[memory_indexer] deep sleep started")
    run_deep_sleep_passes(@deep_sleep_passes)
    Logger.debug("[memory_indexer] deep sleep complete")
  end

  defp run_deep_sleep_passes(0) do
    Logger.debug("[memory_indexer] deep sleep pass limit reached")
    :ok
  end

  defp run_deep_sleep_passes(passes_remaining) do
    with {:ok, global_pairs} <- find_consolidation_pairs(:global),
         {:ok, project_pairs} <- find_consolidation_pairs(:project) do
      all_pairs = global_pairs ++ project_pairs
      pass = @deep_sleep_passes - passes_remaining + 1

      Logger.debug(
        "[memory_indexer] deep sleep pass #{pass}: #{length(all_pairs)} pair(s) to evaluate"
      )

      case all_pairs do
        [] ->
          Logger.debug("[memory_indexer] deep sleep: no pairs above threshold - done")
          :ok

        _ ->
          all_pairs
          |> Services.Globals.Spawn.async_stream(fn {scope, a, b} ->
            consolidate_pair(scope, a, b)
          end)
          |> Enum.to_list()

          run_deep_sleep_passes(passes_remaining - 1)
      end
    end
  end

  # Build the set of non-overlapping pairs above the similarity threshold for
  # a single scope. Highest-scoring pairs are preferred; once a memory appears
  # in a selected pair it is excluded from further pairs in this pass.
  defp find_consolidation_pairs(scope) do
    with {:ok, memories} <- load_memories_for_dedup(scope) do
      pairs =
        memories
        |> all_pairs_above_threshold()
        |> select_non_overlapping()
        |> Enum.map(fn {_score, a, b} -> {scope, a, b} end)

      {:ok, pairs}
    end
  end

  # Load all long-term memories for a scope, generating embeddings for any
  # that are missing them. Memories that fail to load or embed are skipped.
  defp load_memories_for_dedup(scope) do
    with {:ok, titles} <- Memory.list(scope) do
      memories =
        titles
        |> Enum.reduce([], fn title, acc ->
          case Memory.read(scope, title) do
            {:ok, %Memory{embeddings: nil} = mem} ->
              case Memory.generate_embeddings(mem) do
                {:ok, mem_with_emb} ->
                  Memory.save(mem_with_emb, skip_embeddings: true)
                  [mem_with_emb | acc]

                {:error, _} ->
                  acc
              end

            {:ok, mem} ->
              [mem | acc]

            {:error, _} ->
              acc
          end
        end)
        |> Enum.reverse()

      {:ok, memories}
    end
  end

  defp all_pairs_above_threshold(memories) do
    for a <- memories, b <- memories, a.title < b.title do
      score = AI.Util.cosine_similarity(a.embeddings, b.embeddings)
      {score, a, b}
    end
    |> Enum.filter(fn {score, _, _} -> score >= @deep_sleep_min_score end)
    |> Enum.sort_by(fn {score, _, _} -> score end, :desc)
  end

  # Walk pairs highest-score first. Take a pair only when neither memory has
  # already been claimed by a higher-scoring pair in this pass.
  defp select_non_overlapping(pairs) do
    {selected, _claimed} =
      Enum.reduce(pairs, {[], MapSet.new()}, fn {score, a, b}, {selected, claimed} ->
        if MapSet.member?(claimed, a.title) or MapSet.member?(claimed, b.title) do
          {selected, claimed}
        else
          claimed = claimed |> MapSet.put(a.title) |> MapSet.put(b.title)
          {[{score, a, b} | selected], claimed}
        end
      end)

    Enum.reverse(selected)
  end

  # Ask the deduplicator agent whether two memories should be merged. On a
  # merge decision, save the synthesized memory first, then delete both
  # originals so a failure mid-delete never loses information.
  defp consolidate_pair(_scope, a, b) do
    case AI.Agent.Memory.Deduplicator.run(a, b) do
      {:ok, %{"merge" => true, "title" => title, "content" => content} = result} ->
        topics = Map.get(result, "topics", [])

        merged = %Memory{
          scope: a.scope,
          title: title,
          content: content,
          topics: topics,
          embeddings: nil,
          index_status: nil
        }

        case Memory.save(merged) do
          {:ok, _} ->
            Memory.forget(a)
            Memory.forget(b)
            UI.debug("memory_indexer", "Merged '#{a.title}' + '#{b.title}' -> '#{title}'")

          {:error, reason} ->
            UI.warn(
              "memory_indexer",
              "Failed to save merged memory '#{title}': #{inspect(reason)}"
            )
        end

      {:ok, %{"merge" => false}} ->
        :ok

      {:error, reason} ->
        UI.warn(
          "memory_indexer",
          "Deduplication failed for '#{a.title}' + '#{b.title}': #{inspect(reason)}"
        )
    end
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
         _ <-
           Logger.debug(
             "[memory_indexer] indexing #{length(session_mems)} session memory/memories from #{conversation.id}"
           ),
         {:ok, payload} <- build_indexer_payload(data, session_mems),
         {:ok, response} <- invoke_indexer_agent(payload),
         _ <- Logger.debug("[memory_indexer] agent response: #{inspect(response)}"),
         {:ok, decoded} <- parse_indexer_response(response),
         :ok <- validate_indexer_response(decoded) do
      # Pass the payload titles so apply_actions_and_mark can treat all
      # memories given to the agent as processed, regardless of what titles
      # the agent echoes back. Agents are unreliable at exact string matching.
      payload_titles = Enum.map(session_mems, & &1.title)
      apply_actions_and_mark(conversation, decoded, payload_titles)
    else
      [] ->
        :ok

      other ->
        Logger.debug("[memory_indexer] with-else: #{inspect(other)}")
        :ok
    end
  rescue
    e ->
      Logger.debug("[memory_indexer] processing failed: #{Exception.message(e)}")
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

  defp valid_action?(%{"action" => action, "target" => target} = candidate)
       when action in ["add", "replace", "delete"] do
    valid_target?(target) and valid_action_content?(action, candidate)
  end

  defp valid_action?(_), do: false

  defp valid_target?(%{"scope" => scope, "title" => title}) do
    Memory.ScopePolicy.valid_long_term_target?(title, scope)
  end

  defp valid_target?(_), do: false

  defp valid_action_content?("delete", _candidate), do: true

  defp valid_action_content?(action, %{"content" => content}) when action in ["add", "replace"] do
    is_binary(content) and String.trim(content) != ""
  end

  defp valid_action_content?(_, _), do: false

  # --------------------------------------------------------------------------
  # Apply actions and derive handled session-memory titles
  # --------------------------------------------------------------------------
  # payload_titles: the session memory titles passed to the indexer agent.
  # These are merged with the agent's processed list so that all memories given
  # to the agent are marked as at minimum :analyzed after a valid response.
  # Agents often paraphrase or hallucinate titles; relying on exact echoes back
  # from the agent causes memories to stay :new forever and loop indefinitely.
  defp apply_actions_and_mark(conversation, decoded, payload_titles) do
    actions = Map.get(decoded, "actions", [])
    agent_processed = Map.get(decoded, "processed", [])
    status_updates = Map.get(decoded, "status_updates", %{})
    processed = Enum.uniq(payload_titles ++ agent_processed)

    Logger.debug(
      "[memory_indexer] apply: #{length(actions)} action(s), processed=#{inspect(processed)}, status_updates=#{inspect(status_updates)}"
    )

    result =
      FileLock.with_lock(conversation.store_path, fn ->
        with {:ok, fresh} <- Store.Project.Conversation.read(conversation) do
          handled = collect_handled_titles(actions)

          Logger.debug("[memory_indexer] handled=#{inspect(handled)}")

          updated =
            fresh
            |> Map.put(
              :memory,
              mark_processed(fresh.memory, handled, processed, status_updates)
            )

          write_result = Store.Project.Conversation.write(conversation, updated)
          Logger.debug("[memory_indexer] write result: #{inspect(write_result)}")
          write_result
        end
      end)

    Logger.debug("[memory_indexer] apply_actions_and_mark result: #{inspect(result)}")
    result
  end

  defp collect_handled_titles(actions) do
    actions
    |> Enum.reduce(MapSet.new(), fn action, handled ->
      case apply_action(action) do
        {:ok, source_title} when is_binary(source_title) ->
          MapSet.put(handled, source_title)

        {:ok, _} ->
          handled

        {:error, _reason} ->
          handled
      end
    end)
    |> MapSet.to_list()
  end

  # First pass: mark session memories as :analyzed only when confirmed in the
  # handled set (a successful action with a matching "from" field). Second pass:
  # apply status_updates for titles in handled_set or, for all valid statuses,
  # in processed_set. This lets replace/delete actions (which lack "from")
  # still reach :incorporated/:merged via status_updates + processed.
  defp mark_processed(memories, handled, processed, status_updates) do
    handled_set = MapSet.new(handled)
    processed_set = MapSet.new(processed)
    session_titles = session_memory_titles(memories)

    status_update_titles =
      eligible_status_update_titles(status_updates, session_titles, handled_set, processed_set)

    memories
    |> Enum.map(fn
      %Memory{scope: :session, title: title} = mem ->
        mark_memory_analyzed(mem, title, handled_set, processed_set)

      other ->
        other
    end)
    |> Enum.map(fn
      %Memory{scope: :session, title: title} = mem ->
        maybe_apply_status_update(mem, title, status_update_titles, status_updates)

      other ->
        other
    end)
  end

  defp session_memory_titles(memories) do
    memories
    |> Enum.reduce(MapSet.new(), fn
      %Memory{scope: :session, title: title}, acc when is_binary(title) -> MapSet.put(acc, title)
      _, acc -> acc
    end)
  end

  @valid_statuses ["analyzed", "rejected", "incorporated", "merged"]
  defp eligible_status_update_titles(status_updates, session_titles, handled_set, processed_set) do
    status_updates
    |> Enum.reduce(MapSet.new(), fn {title, status}, acc ->
      eligible? =
        MapSet.member?(session_titles, title) and
          (MapSet.member?(handled_set, title) or MapSet.member?(processed_set, title)) and
          status in @valid_statuses

      case eligible? do
        true -> MapSet.put(acc, title)
        false -> acc
      end
    end)
  end

  defp mark_memory_analyzed(mem, title, handled_set, processed_set) do
    if MapSet.member?(handled_set, title) or MapSet.member?(processed_set, title) do
      %{mem | index_status: :analyzed}
    else
      mem
    end
  end

  defp maybe_apply_status_update(mem, title, eligible_titles, status_updates) do
    case MapSet.member?(eligible_titles, title) do
      true -> apply_status_update(mem, Map.get(status_updates, title))
      false -> mem
    end
  end

  defp apply_status_update(mem, status) when status in @valid_statuses do
    %{mem | index_status: String.to_existing_atom(status)}
  end

  defp apply_status_update(mem, _), do: mem

  # --------------------------------------------------------------------------
  # Action dispatch
  # --------------------------------------------------------------------------
  defp apply_action(%{"action" => "add", "target" => target, "content" => content} = action) do
    case call_lt_memory("remember", target, content) do
      :ok -> action_success_source(action)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_action(%{"action" => "replace", "target" => target, "content" => content} = action) do
    case call_lt_memory("update", target, content) do
      :ok -> action_success_source(action)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_action(%{"action" => "delete", "target" => target} = action) do
    case call_lt_memory("forget", target, nil) do
      :ok -> action_success_source(action)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_action(_), do: {:error, :invalid_action}

  defp action_success_source(action) do
    case Map.get(action, "from") do
      %{"title" => title} when is_binary(title) -> {:ok, title}
      title when is_binary(title) -> {:ok, title}
      _ -> {:ok, :no_source}
    end
  end

  defp call_lt_memory(action, %{"scope" => scope, "title" => title}, content) do
    args =
      %{"action" => action, "scope" => scope, "title" => title}
      |> maybe_put_content(content)

    case AI.Tools.perform_tool_call("long_term_memory_tool", args, @lt_memory_tool) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        UI.debug("memory_indexer", "#{action} failed: #{inspect(reason)}")
        {:error, reason}
    end
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
  exist, and `release_lock/1` may temporarily rename that directory to
  `*.json.lock.released.*` before removing it. This maintenance path
  intentionally mirrors that lifecycle: it only inspects those lock-directory
  forms under the project and global memory storage roots, leaves allocation
  locks and unrelated store locks alone, and only removes a lock when the
  target file is missing, the lock age is strictly greater than the stale
  threshold, and no live local owner pid can be found.
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
    memory_lock_patterns(storage_root)
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
  end

  @spec memory_lock_patterns(String.t()) :: [String.t()]
  defp memory_lock_patterns(storage_root) do
    [
      Path.join(storage_root, "*.json.lock"),
      Path.join(storage_root, "*.json.lock.released.*")
    ]
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
    lock_dir
    |> memory_file_for_lock()
    |> File.exists?()
    |> Kernel.not()
  end

  @spec memory_file_for_lock(String.t()) :: String.t()
  defp memory_file_for_lock(lock_dir) do
    lock_dir
    |> normalize_lock_dir_path()
    |> Path.rootname(".lock")
  end

  @spec normalize_lock_dir_path(String.t()) :: String.t()
  defp normalize_lock_dir_path(lock_dir) do
    dirname = Path.dirname(lock_dir)
    basename = Path.basename(lock_dir)

    Path.join(dirname, normalize_lock_dir_basename(basename))
  end

  @spec normalize_lock_dir_basename(String.t()) :: String.t()
  defp normalize_lock_dir_basename(basename) do
    case released_lock_basename?(basename) do
      true -> released_lock_target_basename(basename)
      false -> basename
    end
  end

  @spec released_lock_basename?(String.t()) :: boolean()
  defp released_lock_basename?(basename) do
    case Regex.run(~r/^.+\.json\.lock\.released\..+$/, basename) do
      nil -> false
      _ -> true
    end
  end

  @spec released_lock_target_basename(String.t()) :: String.t()
  defp released_lock_target_basename(basename) do
    case Regex.run(~r/^(?<target>.+\.json\.lock)\.released\..+$/, basename, capture: :all_names) do
      [target] -> target
      [] -> basename
    end
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
