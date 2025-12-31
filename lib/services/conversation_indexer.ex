defmodule Services.ConversationIndexer do
  @moduledoc """
  Background indexer for conversations.

  This GenServer mirrors `Services.BackgroundIndexer`, but operates on
  conversations instead of file entries. It processes one conversation at a
  time, generating embeddings from the conversation messages JSON and writing
  them to the conversation index.
  """

  @max_per_session 10

  use GenServer, restart: :temporary

  @type state :: %{
          project: Store.Project.t() | nil,
          impl: module(),
          convo_queue: [Store.Project.Conversation.t()],
          task: pid() | nil,
          mon_ref: reference() | nil,
          seen: map
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec stop(pid() | any()) :: :ok
  def stop(pid) when is_pid(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _reason -> :ok
    end
  end

  def stop(_), do: :ok

  @impl true
  def init(opts) do
    # Use the dedicated AI indexer HTTP pool
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

    convo_queue =
      case Keyword.get(opts, :conversations) do
        list when is_list(list) -> list
        _ -> []
      end

    state = %{
      project: project,
      impl: Indexer.impl(),
      convo_queue: convo_queue,
      task: nil,
      mon_ref: nil,
      seen: %{}
    }

    {:ok, state, {:continue, :process_next}}
  end

  @impl true
  def handle_continue(:process_next, %{task: pid} = state) when is_pid(pid) do
    {:noreply, state}
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, convo_queue: [convo | rest]} = state) do
    {:ok, task_pid} = Task.start_link(fn -> safe_process(convo, state.impl, state.project) end)
    mon_ref = Process.monitor(task_pid)
    new_state = %{state | task: task_pid, mon_ref: mon_ref, convo_queue: rest}
    {:noreply, new_state}
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, convo_queue: [], project: project} = state)
      when not is_nil(project) do
    state
    |> next_stale_conversation()
    |> case do
      nil ->
        {:stop, :normal, state}

      convo ->
        {:ok, task_pid} =
          Task.start_link(fn ->
            safe_process(convo, state.impl, state.project)
          end)

        mon_ref = Process.monitor(task_pid)

        new_state = %{
          state
          | task: task_pid,
            mon_ref: mon_ref,
            seen: Map.put(state.seen, convo.id, true)
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, convo_queue: [], project: nil} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{mon_ref: ref, task: pid} = state) do
    new_state = %{state | task: nil, mon_ref: nil}
    {:noreply, new_state, {:continue, :process_next}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case state do
      %{task: pid} when is_pid(pid) -> Process.exit(pid, :kill)
      _ -> :ok
    end

    HttpPool.clear()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Per-conversation processing
  # ---------------------------------------------------------------------------

  @spec safe_process(Store.Project.Conversation.t(), module, Store.Project.t() | nil) :: :ok
  defp safe_process(convo, impl, project) do
    try do
      case Store.Project.Conversation.read(convo) do
        {:ok, %{timestamp: ts, messages: messages, metadata: metadata}} ->
          json = Jason.encode!(%{"messages" => messages})

          with {:ok, embeddings} <- impl.get_embeddings(json) do
            meta =
              metadata
              |> Map.merge(%{
                "conversation_id" => convo.id,
                "last_indexed_ts" => DateTime.to_unix(ts),
                "message_count" => length(messages)
              })

            case project do
              %Store.Project{} = prj ->
                :ok =
                  Store.Project.ConversationIndex.write_embeddings(
                    prj,
                    convo.id,
                    embeddings,
                    meta
                  )

                label = get_label(convo)
                UI.end_step_background("Indexed", "<chat> " <> label)

              _ ->
                :ok
            end
          end

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  @spec next_stale_conversation(state) :: Store.Project.Conversation.t() | nil
  defp next_stale_conversation(%{project: project, seen: seen}) do
    if map_size(seen) >= @max_per_session do
      nil
    else
      project
      |> Store.Project.ConversationIndex.index_status()
      |> Map.take([:new, :stale])
      |> Map.values()
      |> List.flatten()
      |> Enum.reject(fn convo -> Map.has_key?(seen, convo.id) end)
      |> List.first()
    end
  end

  defp get_label(conversation) do
    with {:ok, question} <- Store.Project.Conversation.question(conversation) do
      width =
        Owl.IO.columns() -
          String.length("[info] ✓ Reindexed: [xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx] ")

      question
      |> String.split("\n")
      # Find the first line that contains alphanumeric characters
      |> Enum.find("(no title)", fn line -> String.match?(line, ~r/\p{L}|\p{N}/u) end)
      |> String.trim()
      |> then(fn line ->
        Owl.Data.truncate(
          [
            Owl.Data.tag("[#{conversation.id}] ", :normal),
            Owl.Data.tag(line, [:italic, :light_black])
          ],
          width
        )
        |> Owl.Data.to_chardata()
        |> to_string()
      end)
    end
  end
end
