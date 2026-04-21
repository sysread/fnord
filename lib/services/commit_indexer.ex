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
          candidates: [map()]
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

    # Resolve the candidate list up front. index_status/1 enumerates the
    # project's full commit history (one `git show` per commit) and is too
    # expensive to re-run on every cycle. Budget the work to
    # @max_commits_per_session now and pop one entry per cycle until the
    # list is empty.
    candidates = resolve_candidates(project)

    state = %{
      project: project,
      task: nil,
      mon_ref: nil,
      impl: Indexer.impl(),
      candidates: candidates
    }

    {:ok, state, {:continue, :process_next}}
  end

  @impl true
  def handle_continue(:process_next, %{task: pid} = state) when is_pid(pid) do
    {:noreply, state}
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, candidates: []} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_continue(:process_next, %{task: nil, project: project} = state)
      when not is_nil(project) do
    if GitCli.is_git_repo_at?(Store.Project.original_source_root()) do
      case state.candidates do
        [commit | rest] ->
          case start_commit_task(commit, %{state | candidates: rest}) do
            {:noreply, new_state} -> {:noreply, new_state}
            other -> other
          end

        [] ->
          {:stop, :normal, state}
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
    if Services.BgIndexingControl.paused?("embeddings") do
      {:stop, :normal, state}
    else
      {:ok, task_pid} = Task.start_link(fn -> safe_process(commit, state.impl, state.project) end)
      mon_ref = Process.monitor(task_pid)

      {:noreply, %{state | task: task_pid, mon_ref: mon_ref}}
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

  defp resolve_candidates(nil), do: []

  defp resolve_candidates(%Store.Project{} = project) do
    unless GitCli.is_git_repo_at?(Store.Project.original_source_root()) do
      []
    else
      status = CommitIndex.index_status(project)

      (status.new ++ status.stale)
      |> Enum.take(@max_commits_per_session)
    end
  end
end
