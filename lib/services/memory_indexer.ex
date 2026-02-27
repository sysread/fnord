defmodule Services.MemoryIndexer do
  @moduledoc """
  GenServer wrapper for analyzing session memories and applying long-term
  memory actions. This service provides a queue and a small worker pool to
  process conversations concurrently.

  Public API:
  - start_link/1
  - enqueue(conversation)
  - process_sync(conversation)
  - status()

  It is intentionally conservative: processing is performed in tasks and
  failures are isolated so that a bad conversation does not stop the system.
  """

  use GenServer

  @default_workers 4
  @lt_memory_tool %{"long_term_memory_tool" => AI.Tools.LongTermMemory}

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue a conversation for background analysis"
  def enqueue(convo) do
    GenServer.cast(__MODULE__, {:enqueue, convo})
  end

  @doc "Process a conversation synchronously; returns :ok | {:error, term()}"
  def process_sync(convo) do
    GenServer.call(__MODULE__, {:process_sync, convo}, :infinity)
  end

  @doc "Get status about queue length and in-flight tasks"
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  # --------------------------------------------------------------------------
  # GenServer callbacks
  # --------------------------------------------------------------------------
  def init(opts) do
    workers =
      Keyword.get(opts, :workers, Services.Globals.get_env(:fnord, :workers, @default_workers))

    {:ok, sup} = Task.Supervisor.start_link(name: Services.MemoryIndexer.Supervisor)

    {:ok, %{queue: :queue.new(), workers: workers, running: %{}, sup: sup}}
  end

  def handle_cast({:enqueue, convo}, state) do
    new_queue = :queue.in(convo, state.queue)
    {:noreply, %{state | queue: new_queue}, {:continue, :drain}}
  end

  def handle_continue(:drain, state) do
    spawn_workers(state)
  end

  # Compile-time environment gate. process_sync blocks the GenServer for the
  # entire LLM round-trip, which is fine for deterministic test execution but
  # would deadlock the worker pool in production. Rather than trusting callers
  # to know this, we simply don't compile the working implementation outside
  # of test. Yes, this is a compile-time conditional in application code. We
  # are not proud, but we are correct.
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
    {:reply, %{queue_len: :queue.len(state.queue), running: map_size(state.running)}, state}
  end

  # Task completion: clean up the running map and drain more work.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, _} -> {:noreply, state}
      {_entry, running2} -> spawn_workers(%{state | running: running2})
    end
  end

  # Task crash: find by pid, remove from running, drain more work.
  def handle_info({:DOWN, _monitor_ref, :process, pid, _reason}, state) do
    case Enum.find(state.running, fn {_ref, {p, _convo}} -> p == pid end) do
      nil ->
        {:noreply, state}

      {ref, _} ->
        {_entry, running2} = Map.pop(state.running, ref)
        spawn_workers(%{state | running: running2})
    end
  end

  # --------------------------------------------------------------------------
  # Worker pool
  # --------------------------------------------------------------------------
  defp spawn_workers(state) do
    available = max(state.workers - map_size(state.running), 0)
    {to_start, q} = dequeue_n(state.queue, available)

    new_running =
      Enum.reduce(to_start, state.running, fn convo, acc ->
        task =
          Services.Globals.Spawn.async(fn ->
            HttpPool.set(:ai_memory)
            do_process_conversation(convo)
          end)

        Map.put(acc, task.ref, {task.pid, convo})
      end)

    {:noreply, %{state | queue: q, running: new_running}}
  end

  defp dequeue_n(queue, 0), do: {[], queue}

  defp dequeue_n(queue, n) when n > 0 do
    do_dequeue_n(queue, n, [])
  end

  defp do_dequeue_n(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp do_dequeue_n(queue, n, acc) do
    case :queue.out(queue) do
      {:empty, q} -> {Enum.reverse(acc), q}
      {{:value, v}, q2} -> do_dequeue_n(q2, n - 1, [v | acc])
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
         {:ok, payload} <- build_indexer_payload(data, session_mems),
         {:ok, response} <- invoke_indexer_agent(payload),
         {:ok, decoded} <- parse_indexer_response(response),
         :ok <- validate_indexer_response(decoded) do
      apply_actions_and_mark(conversation, decoded)
    else
      # No unprocessed memories -- nothing to do.
      [] -> :ok
      # Conversation unreadable or other non-critical failure.
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

    {:ok, Jason.encode!(payload)}
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
    case Jason.decode(response) do
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
