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

  # Public API
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

  # GenServer callbacks
  def init(opts) do
    workers =
      Keyword.get(opts, :workers, Services.Globals.get_env(:fnord, :workers, @default_workers))

    # Use a Task.Supervisor for worker tasks so they are supervised
    {:ok, sup} = Task.Supervisor.start_link(name: Services.MemoryIndexer.Supervisor)

    state = %{
      queue: :queue.new(),
      workers: workers,
      running: %{},
      sup: sup
    }

    {:ok, state}
  end

  def handle_cast({:enqueue, convo}, state) do
    new_queue = :queue.in(convo, state.queue)
    {:noreply, %{state | queue: new_queue}, {:continue, :drain}}
  end

  def handle_continue(:drain, state) do
    spawn_workers(state)
  end

  def handle_call({:process_sync, convo}, _from, state) do
    res = do_process_conversation(convo)
    {:reply, res, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{queue_len: :queue.len(state.queue), running: map_size(state.running)}, state}
  end

  # Spawn tasks up to configured workers, draining queue
  defp spawn_workers(state) do
    available = max(state.workers - map_size(state.running), 0)

    {to_start, q} = dequeue_n(state.queue, available)

    new_running =
      Enum.reduce(to_start, state.running, fn convo, acc ->
        task =
          Services.Globals.Spawn.async(fn ->
            do_process_conversation(convo)
          end)

        ref = task.ref
        # Record the task pid and conversation for bookkeeping
        Map.put(acc, ref, {task.pid, convo})
      end)

    {:noreply, %{state | queue: q, running: new_running}}
  end

  # Handle the Task result message ({ref, result}) which Task sends to the
  # caller on completion, and also handle generic :DOWN messages for crashed
  # tasks (monitor ref not equal to task.ref). We key `running` by task.ref.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, _} -> {:noreply, state}
      {_entry, running2} -> spawn_workers(%{state | running: running2})
    end
  end

  def handle_info({:DOWN, _monitor_ref, :process, pid, _reason}, state) do
    # Find any running entry by pid and remove it
    case Enum.find(state.running, fn {_ref, {p, _convo}} -> p == pid end) do
      nil ->
        {:noreply, state}

      {ref, _} ->
        {_entry, running2} = Map.pop(state.running, ref)
        spawn_workers(%{state | running: running2})
    end
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

  @spec do_process_conversation(any()) :: :ok | {:error, any()}
  defp do_process_conversation(convo) do
    process_conversation_impl(convo)
  rescue
    e -> {:error, e}
  end

  # Implementation moved from Memory.SessionIndexer into this service so the
  # GenServer owns the processing lifecycle and queueing.
  @spec process_conversation_impl(any()) :: :ok | {:error, any()}
  defp process_conversation_impl(conversation) do
    try do
      case Store.Project.Conversation.read(conversation) do
        {:ok, data} ->
          session_mems =
            data
            |> Map.get(:memory, [])
            |> Enum.filter(fn
              %Memory{scope: :session} = m -> is_nil(m.index_status) or m.index_status == :new
              _ -> false
            end)

          if session_mems == [] do
            :ok
          else
            # For each session memory, gather recall candidates from long-term
            # storage (project/global) and from other session conversations. We
            # include these candidate lists in the payload so the LLM indexer
            # can reason with provenance without needing to call tools.
            memories_with_candidates =
              Enum.map(session_mems, fn m ->
                project_candidates =
                  case AI.Tools.LongTermMemory.call(%{
                         "action" => "recall",
                         "query" => m.content,
                         "search_type" => "project_global",
                         "limit" => 5
                       }) do
                    {:ok, res} -> res
                    {:error, _} -> []
                  end

                session_candidates =
                  case AI.Tools.LongTermMemory.call(%{
                         "action" => "recall",
                         "query" => m.content,
                         "search_type" => "session_conversations",
                         "limit" => 5,
                         "provenance_only" => true
                       }) do
                    {:ok, res} -> res
                    {:error, _} -> []
                  end

                %{
                  title: m.title,
                  content: m.content,
                  topics: m.topics,
                  project_candidates: project_candidates,
                  session_candidates: session_candidates
                }
              end)

            payload = %{
              conversation_summary: summarize_conversation(data.messages),
              memories: memories_with_candidates
            }

            json_payload = Jason.encode!(payload)

            agent = AI.Agent.new(AI.Agent.Memory.Indexer, named?: false)

            case AI.Agent.get_response(agent, %{payload: json_payload}) do
              {:ok, resp} ->
                case Jason.decode(resp) do
                  {:ok, %{"actions" => actions, "processed" => processed} = decoded} ->
                    # Optional status_updates map (title -> status string)
                    status_updates = Map.get(decoded, "status_updates", %{})

                    # Validate actions and processed structure before applying
                    case validate_actions_and_processed(actions, processed, status_updates) do
                      :ok ->
                        apply_actions_and_mark_impl(
                          conversation,
                          data,
                          actions,
                          processed,
                          status_updates
                        )

                      {:error, reason} ->
                        UI.error("memory_indexer", "Invalid indexer response: #{inspect(reason)}")
                        {:error, :invalid_response}
                    end

                  _ ->
                    {:error, :invalid_response}
                end

              {:error, _} ->
                {:error, :agent_failed}
            end
          end

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  def summarize_conversation(messages) when is_list(messages),
    do: summarize_conversation_impl(messages)

  def summarize_conversation(_), do: ""

  defp summarize_conversation_impl(messages) when is_list(messages) do
    # Reuse the concise deterministic summary used previously.
    user_msg =
      messages
      |> Enum.find(fn
        %{role: "user"} -> true
        _ -> false
      end)
      |> case do
        %{content: c} -> String.slice(c, 0, 400)
        _ -> ""
      end

    assistant_msg =
      messages
      |> Enum.reverse()
      |> Enum.find(fn
        %{role: "assistant", content: c} when is_binary(c) ->
          not String.starts_with?(c, "<think>")

        _ ->
          false
      end)
      |> case do
        %{content: c} -> String.slice(c, 0, 400)
        _ -> ""
      end

    cond do
      user_msg == "" and assistant_msg == "" -> ""
      assistant_msg == "" -> "User: " <> user_msg
      user_msg == "" -> "Assistant: " <> assistant_msg
      true -> "User: " <> user_msg <> " \nAssistant: " <> assistant_msg
    end
  end

  defp summarize_conversation_impl(_), do: ""

  defp apply_actions_and_mark_impl(conversation, _data, actions, processed, status_updates) do
    unless is_list(actions) and is_list(processed) do
      {:error, :invalid_schema}
    else
      lockfile = conversation.store_path

      FileLock.with_lock(lockfile, fn ->
        {:ok, fresh} = Store.Project.Conversation.read(conversation)

        Enum.each(actions, fn action ->
          maybe_apply_action_impl(action)
        end)

        updated_memories =
          fresh.memory
          |> Enum.map(fn
            %Memory{scope: :session, title: title} = m ->
              if title in processed, do: %{m | index_status: :analyzed}, else: m

            other ->
              other
          end)

        # Apply explicit status updates if the agent provided them
        updated_memories =
          Enum.map(updated_memories, fn
            %Memory{scope: :session, title: title} = m ->
              case Map.get(status_updates, title) do
                status when status in ["analyzed", "rejected", "incorporated", "merged"] ->
                  %{m | index_status: String.to_existing_atom(status)}

                _ ->
                  m
              end

            other ->
              other
          end)

        data = Map.put(fresh, :memory, updated_memories)
        Store.Project.Conversation.write(conversation, data)
      end)

      :ok
    end
  end

  defp validate_actions_and_processed(actions, processed, status_updates) do
    cond do
      not is_list(actions) ->
        {:error, "actions must be a list"}

      not is_list(processed) ->
        {:error, "processed must be a list"}

      not is_map(status_updates) ->
        {:error, "status_updates must be a map"}

      true ->
        # Minimal validation of action objects and processed list strings
        cond do
          not Enum.all?(processed, &is_binary/1) ->
            {:error, "processed must be list of strings"}

          not Enum.all?(actions, &valid_action?/1) ->
            {:error, "invalid action object in actions"}

          true ->
            :ok
        end
    end
  end

  defp valid_action?(%{"action" => a, "target" => %{"scope" => _s, "title" => _t}})
       when a in ["add", "replace", "delete"], do: true

  defp valid_action?(_), do: false

  defp maybe_apply_action_impl(%{
         "action" => "add",
         "target" => %{"scope" => scope, "title" => title},
         "from" => %{"title" => _from_title},
         "content" => content
       }) do
    result =
      AI.Tools.perform_tool_call(
        "long_term_memory_tool",
        %{"action" => "remember", "scope" => scope, "title" => title, "content" => content},
        %{"long_term_memory_tool" => AI.Tools.LongTermMemory}
      )

    # Debug output to assist diagnosing test issues — important to keep
    # concise and removed once root cause is resolved.

    case result do
      {:ok, _} ->
        # Verify the memory exists in the target scope; best-effort check for tests
        read_result = Memory.read(String.to_atom(scope), title)

        case read_result do
          {:ok, _mem} ->
            :ok

          _ ->
            UI.debug(
              "memory_indexer",
              "long_term remember call succeeded but memory not found for #{inspect(title)} in #{scope}"
            )
        end

      {:error, reason} ->
        UI.debug("memory_indexer", "long_term remember failed: #{inspect(reason)}")
    end

    :ok
  end

  defp maybe_apply_action_impl(%{
         "action" => "replace",
         "target" => %{"scope" => scope, "title" => title},
         "content" => content
       }) do
    result =
      AI.Tools.perform_tool_call(
        "long_term_memory_tool",
        %{"action" => "update", "scope" => scope, "title" => title, "new_content" => content},
        %{"long_term_memory_tool" => AI.Tools.LongTermMemory}
      )

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        UI.debug("memory_indexer", "long_term update failed: #{inspect(reason)}")
    end

    :ok
  end

  defp maybe_apply_action_impl(%{
         "action" => "delete",
         "target" => %{"scope" => scope, "title" => title}
       }) do
    result =
      AI.Tools.perform_tool_call(
        "long_term_memory_tool",
        %{"action" => "forget", "scope" => scope, "title" => title},
        %{"long_term_memory_tool" => AI.Tools.LongTermMemory}
      )

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        UI.debug("memory_indexer", "long_term forget failed: #{inspect(reason)}")
    end

    :ok
  end

  defp maybe_apply_action_impl(_), do: :ok
end
