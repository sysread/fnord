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
      UI.spin("Deleting missing and newly excluded files from index", fn ->
        count = Store.Project.delete_missing_files(idx.project) |> Enum.count()
        {"Deleted #{count} file(s) from the index", :ok}
      end)
    end

    all_files =
      UI.spin("Scanning project files", fn ->
        files = Store.Project.source_files(idx.project) |> Enum.to_list()
        {"There are #{Enum.count(files)} indexable file(s) in project", files}
      end)

    stale_files =
      UI.spin("Identifying stale files", fn ->
        files = Store.Project.stale_source_files(all_files) |> Enum.to_list()
        {"Identified #{Enum.count(files)} stale file(s) to index", files}
      end)

    total = Enum.count(all_files)
    count = Enum.count(stale_files)

    if count == 0 do
      UI.warn("No files to index in #{idx.project.name}")
    else
      UI.spin("Indexing #{count} / #{total} files", fn ->
        stale_files
        |> UI.async_stream(&process_entry(idx, &1), "Indexing")
        |> Enum.to_list()

        {"All file indexing tasks complete", :ok}
      end)
    end
  end

  defp process_entry(idx, entry) do
    with {:ok, contents} <- Store.Project.Entry.read_source_file(entry),
         {:ok, summary, outline} <- get_derivatives(idx, entry.file, contents),
         {:ok, embeddings} <- get_embeddings(idx, entry.file, summary, outline, contents),
         :ok <- Store.Project.Entry.save(entry, summary, outline, embeddings) do
      # If :quiet is true, the progress bar will be absent, so instead, we'll
      # emit debug logs to stderr. The user can control whether those are
      # displayed by setting LOGGER_LEVEL.
      if Application.get_env(:fnord, :quiet) do
        UI.debug("✓ #{entry.file}")
      end

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
    Indexer.impl().get_outline(idx.indexer, file, file_contents)
  end

  defp get_summary(idx, file, file_contents) do
    Indexer.impl().get_summary(idx.indexer, file, file_contents)
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

    Indexer.impl().get_embeddings(idx.indexer, to_embed)
    |> case do
      {:error, reason} -> reason |> IO.inspect()
      other -> other
    end
  end
end
