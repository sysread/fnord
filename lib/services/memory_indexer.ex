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
          Task.Supervisor.async_nolink(Services.MemoryIndexer.Supervisor, fn ->
            do_process_conversation(convo)
          end)

        ref = task.ref
        # Task.Supervisor.async_nolink already sets up a monitor and returns the monitor ref
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

  defp do_process_conversation(convo) do
    process_conversation_impl(convo)
  rescue
    e -> {:error, e}
  end

  # Implementation moved from Memory.SessionIndexer into this service so the
  # GenServer owns the processing lifecycle and queueing.
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
            payload = %{
              conversation_summary: summarize_conversation(data.messages),
              memories:
                Enum.map(session_mems, fn m ->
                  %{title: m.title, content: m.content, topics: m.topics}
                end)
            }

            json_payload = Jason.encode!(payload)
            agent = AI.Agent.new(AI.Agent.Memory.Indexer, named?: false)

            case AI.Agent.get_response(agent, %{payload: json_payload}) do
              {:ok, resp} ->
                case Jason.decode(resp) do
                  {:ok, %{"actions" => actions, "processed" => processed}} ->
                    apply_actions_and_mark_impl(conversation, data, actions, processed)

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

  defp apply_actions_and_mark_impl(conversation, _data, actions, processed) do
    unless is_list(actions) and is_list(processed) do
      {:error, :invalid_schema}
    else
      lockfile = conversation.store_path

      FileLock.with_lock(lockfile, fn ->
        {:ok, fresh} = Store.Project.Conversation.read(conversation)

        Enum.each(actions, fn action -> maybe_apply_action_impl(action) end)

        updated_memories =
          fresh.memory
          |> Enum.map(fn
            %Memory{scope: :session, title: title} = m ->
              if title in processed, do: %{m | index_status: :analyzed}, else: m

            other ->
              other
          end)

        data = Map.put(fresh, :memory, updated_memories)
        Store.Project.Conversation.write(conversation, data)
      end)

      :ok
    end
  end

  defp maybe_apply_action_impl(%{
         "action" => "add",
         "target" => %{"scope" => scope, "title" => title},
         "from" => %{"title" => _from_title},
         "content" => content
       }) do
    AI.Tools.perform_tool_call(
      "long_term_memory_tool",
      %{"action" => "remember", "scope" => scope, "title" => title, "content" => content},
      %{"long_term_memory_tool" => AI.Tools.LongTermMemory}
    )

    :ok
  end

  defp maybe_apply_action_impl(%{
         "action" => "replace",
         "target" => %{"scope" => scope, "title" => title},
         "content" => content
       }) do
    AI.Tools.perform_tool_call(
      "long_term_memory_tool",
      %{"action" => "update", "scope" => scope, "title" => title, "new_content" => content},
      %{"long_term_memory_tool" => AI.Tools.LongTermMemory}
    )

    :ok
  end

  defp maybe_apply_action_impl(%{
         "action" => "delete",
         "target" => %{"scope" => scope, "title" => title}
       }) do
    AI.Tools.perform_tool_call(
      "long_term_memory_tool",
      %{"action" => "forget", "scope" => scope, "title" => title},
      %{"long_term_memory_tool" => AI.Tools.LongTermMemory}
    )

    :ok
  end

  defp maybe_apply_action_impl(_), do: :ok
end
