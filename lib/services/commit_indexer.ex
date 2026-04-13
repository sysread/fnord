defmodule Services.CommitIndexer do
  @moduledoc """
  Silent background indexer for git commits.

  The worker mirrors the existing file and conversation indexers: it processes
  one commit at a time, rechecks the project index after each completion, and
  exits cleanly when there is no more work or when the ask session shuts down.
  """

  @max_commits_per_session 10

  use GenServer, restart: :temporary

  alias Store.Project.CommitIndex

  @type state :: %{
          project: Store.Project.t() | nil,
          task: pid() | nil,
          mon_ref: reference() | nil,
          impl: module(),
          seen: map()
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
      :exit, _ -> :ok
    end
  end

  def stop(_), do: :ok

  @impl true
  def init(opts) do
    HttpPool.set(:ai_indexer)
    Services.BgIndexingControl.ensure_init()

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

    state = %{
      project: project,
      task: nil,
      mon_ref: nil,
      impl: Indexer.impl(),
      seen: %{}
    }

    {:ok, state, {:continue, :process_next}}
  end

  @impl true
  def handle_continue(:process_next, %{task: pid} = state) when is_pid(pid) do
    {:noreply, state}
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, project: project} = state)
      when not is_nil(project) do
    if GitCli.is_git_repo_at?(Store.Project.original_source_root()) do
      case next_stale_commit(project, state.seen) do
        nil ->
          {:stop, :normal, state}

        commit ->
          case start_commit_task(commit, state) do
            {:noreply, new_state} -> {:noreply, new_state}
            other -> other
          end
      end
    else
      {:stop, :normal, state}
    end
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, project: nil} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{mon_ref: ref, task: pid} = state) do
    {:noreply, %{state | task: nil, mon_ref: nil}, {:continue, :process_next}}
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

  defp start_commit_task(commit, state) do
    if Services.BgIndexingControl.paused?(AI.Embeddings.model_name()) do
      {:stop, :normal, state}
    else
      {:ok, task_pid} = Task.start_link(fn -> safe_process(commit, state.impl, state.project) end)
      mon_ref = Process.monitor(task_pid)

      {:noreply,
       %{state | task: task_pid, mon_ref: mon_ref, seen: Map.put(state.seen, commit.sha, true)}}
    end
  end

  defp safe_process(commit, impl, project) do
    try do
      %{document: document, metadata: metadata} = CommitIndex.build_metadata(commit)

      with {:ok, embeddings} <- impl.get_embeddings(document),
           :ok <- CommitIndex.write_embeddings(project, commit.sha, embeddings, metadata) do
        # Emit a concise background log line mirroring file bg indexer UX
        subject = Map.get(commit, :subject) || Map.get(commit, "subject") || ""

        UI.end_step_background(
          "Indexed",
          "<commit> #{String.slice(commit.sha, 0, 12)} #{subject}"
        )

        :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp next_stale_commit(project, seen) do
    if map_size(seen) >= @max_commits_per_session do
      nil
    else
      project
      |> CommitIndex.index_status()
      |> Map.take([:new, :stale])
      |> Map.values()
      |> List.flatten()
      |> Enum.reject(fn commit -> Map.has_key?(seen, commit.sha) end)
      |> List.first()
    end
  end
end
