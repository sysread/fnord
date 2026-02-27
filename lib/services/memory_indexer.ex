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
  def init(_opts) do
    {:ok, %{task: nil}, {:continue, :scan}}
  end

  # Scan for the next conversation with unprocessed memories and spawn a
  # background task to process it. If already busy or nothing found, no-op.
  def handle_continue(:scan, %{task: nil} = state) do
    case find_next_conversation() do
      nil ->
        {:noreply, state}

      convo ->
        task = spawn_processing_task(convo)
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

  def handle_info(_msg, state), do: {:noreply, state}

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
  defp spawn_processing_task(convo) do
    Services.Globals.Spawn.async(fn ->
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
