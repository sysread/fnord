defmodule Cmd.Index.Embeddings do
  # ----------------------------------------------------------------------------
  # Options
  # ----------------------------------------------------------------------------
  defp reindex?(idx), do: Map.get(idx.opts, :reindex, false)

  # ----------------------------------------------------------------------------
  # Indexing process
  # ----------------------------------------------------------------------------
  def index_project(idx) do
    if reindex?(idx) do
      Store.Project.delete(idx.project)
      UI.report_step("Burned all of the old data to the ground to force a full reindex!")
    else
      UI.info("Scanning project...")
      Store.Project.delete_missing_files(idx.project)
      UI.report_step("Deleted missing and newly excluded files")
    end

    all_files = Store.Project.source_files(idx.project)
    stale_files = Store.Project.stale_source_files(idx.project)

    total = Enum.count(all_files)
    count = Enum.count(stale_files)

    if count == 0 do
      UI.warn("No files to index in #{idx.project.name}")
    else
      {:ok, queue} = Queue.start_link(&process_entry(idx, &1))

      Cmd.Index.UI.spin("Indexing #{count} / #{total} files", fn ->
        # files * 3 for each step in indexing a file (summary, outline, embeddings)
        Cmd.Index.UI.progress_bar_start(:indexing, "Tasks", count * 3)

        # queue files
        Enum.each(stale_files, &Queue.queue(queue, &1))

        # start a monitor that displays in-progress files
        monitor = Cmd.Index.UI.start_in_progress_jobs_monitor(queue)

        # wait on queue to complete
        Queue.shutdown(queue)
        Queue.join(queue)

        # wait on monitor to terminate
        Task.await(monitor)

        {"All file indexing tasks complete", :ok}
      end)
    end
  end

  defp process_entry(idx, entry) do
    with {:ok, contents} <- Store.Project.Entry.read_source_file(entry),
         {:ok, summary, outline} <- get_derivatives(idx, entry.file, contents),
         {:ok, embeddings} <- get_embeddings(idx, entry.file, summary, outline, contents),
         :ok <- Store.Project.Entry.save(entry, summary, outline, embeddings) do
      UI.debug("✓ #{entry.file}")
      :ok
    else
      {:error, reason} -> UI.warn("Error processing #{entry.file}", inspect(reason))
    end
  end

  defp get_derivatives(idx, file, file_contents) do
    summary_task = Task.async(fn -> get_summary(idx, file, file_contents) end)
    outline_task = Task.async(fn -> get_outline(idx, file, file_contents) end)

    with {:ok, summary} <- Task.await(summary_task, :infinity),
         {:ok, outline} <- Task.await(outline_task, :infinity) do
      {:ok, summary, outline}
    end
  end

  defp get_outline(idx, file, file_contents) do
    res = Indexer.impl().get_outline(idx.indexer, file, file_contents)
    Cmd.Index.UI.progress_bar_update(:indexing)
    res
  end

  defp get_summary(idx, file, file_contents) do
    res = Indexer.impl().get_summary(idx.indexer, file, file_contents)
    Cmd.Index.UI.progress_bar_update(:indexing)
    res
  end

  defp get_embeddings(idx, file, summary, outline, file_contents) do
    to_embed = """
      # File
      `#{file}`

      ## Summary
      #{summary}

      ## Outline
      #{outline}

      ## Contents
      ```
      #{file_contents}
      ```
    """

    result = Indexer.impl().get_embeddings(idx.indexer, to_embed)
    Cmd.Index.UI.progress_bar_update(:indexing)

    case result do
      {:error, reason} -> IO.inspect(reason)
      _ -> nil
    end

    result
  end
end
