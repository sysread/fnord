defmodule Services.BackgroundIndexer do
  @moduledoc """
  A silent, cancellable GenServer that incrementally indexes stale files.
  """

  use GenServer,
    # Do not restart if it crashes; it should stop when done
    restart: :temporary

  @spec start_link(
          opts :: [
            project: Store.Project.t(),
            files: [Store.Project.Entry.t()]
          ]
        ) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    project =
      case Keyword.get(opts, :project) do
        %Store.Project{} = prj ->
          prj

        _ ->
          case Store.get_project() do
            {:ok, prj} ->
              prj

            _ ->
              # no project available; initialize with empty queue
              nil
          end
      end

    queue =
      case Keyword.get(opts, :files) do
        files when is_list(files) ->
          files

        _ ->
          if project do
            Store.Project.index_status(project).stale
          else
            []
          end
      end

    state = %{project: project, queue: queue, impl: Indexer.impl()}
    {:ok, state, {:continue, :process_next}}
  end

  @impl true
  def handle_continue(:process_next, %{queue: []} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_continue(:process_next, %{queue: [entry | rest]} = state) do
    safe_process(entry, state.impl, state.project)
    {:noreply, %{state | queue: rest}, {:continue, :process_next}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # Safely process a single entry: read, generate summary, outline, embeddings, and save
  defp safe_process(entry, impl, _project) do
    try do
      UI.begin_step("Indexing", entry.file)

      content =
        case Store.Project.Entry.read_source_file(entry) do
          {:ok, c} -> c
          _ -> ""
        end

      path = entry.file
      {:ok, summary} = impl.get_summary(path, content)
      {:ok, outline} = impl.get_outline(path, content)
      embed_str = [summary, outline, content] |> Enum.join("\n\n")
      {:ok, embeddings} = impl.get_embeddings(embed_str)
      Store.Project.Entry.save(entry, summary, outline, embeddings)

      UI.end_step("Indexed", entry.file)
    rescue
      _ -> :ok
    end
  end
end
