defmodule Cmd.Indexer do
  defstruct [
    :opts,
    :indexer_module,
    :indexer,
    :project
  ]

  def new(opts, indexer \\ Indexer) do
    project =
      Store.get_project()
      |> Store.Project.save_settings(
        Map.get(opts, :directory),
        Map.get(opts, :exclude)
      )

    if is_nil(project.source_root) do
      raise """
      Error: the project root was not found in the settings file.

      This can happen under the following circumstances:
        - the first index of a project
        - the first index reindexing after moving the project directory
        - the first index after the upgrade that made --dir optional
      """
    end

    %__MODULE__{
      opts: opts,
      indexer_module: indexer,
      indexer: indexer.new(),
      project: project
    }
  end

  def run(idx) do
    UI.info("Project", idx.project.name)
    UI.info("Root", idx.project.source_root)

    UI.info(
      "Exclude",
      idx.project.exclude
      |> Enum.join(" | ")
      |> case do
        "" -> "None"
        x -> x
      end
    )

    if reindex?(idx) do
      Store.Project.delete(idx.project)
      UI.report_step("Burned all of the old data to the ground to force a full reindex!")
    else
      Store.Project.delete_missing_files(idx.project)
      UI.report_step("Deleted missing and newly excluded files")
    end

    {:ok, queue} = Queue.start_link(&process_entry(idx, &1))

    all_files = Store.Project.source_files(idx.project)
    stale_files = Store.Project.stale_source_files(idx.project)

    total = Enum.count(all_files)
    count = Enum.count(stale_files)

    if count == 0 do
      UI.warn("No files to index in #{idx.project.name}")
    else
      spin("Indexing #{count} / #{total} files", fn ->
        # files * 3 for each step in indexing a file (summary, outline, embeddings)
        progress_bar_start(:indexing, "Tasks", count * 3)

        # queue files
        Enum.each(stale_files, &Queue.queue(queue, &1))

        # start a monitor that displays in-progress files
        monitor = start_in_progress_jobs_monitor(queue)

        # wait on queue to complete
        Queue.shutdown(queue)
        Queue.join(queue)

        # wait on monitor to terminate
        Task.await(monitor)

        {"All tasks complete", :ok}
      end)
    end
  end

  # ----------------------------------------------------------------------------
  # Options
  # ----------------------------------------------------------------------------
  defp quiet?(), do: Application.get_env(:fnord, :quiet)
  defp reindex?(idx), do: Map.get(idx.opts, :reindex, false)

  # ----------------------------------------------------------------------------
  # Indexing process
  # ----------------------------------------------------------------------------
  defp process_entry(idx, entry) do
    with {:ok, contents} <- Store.Entry.read_source_file(entry),
         {:ok, summary, outline} <- get_derivatives(idx, entry.file, contents),
         {:ok, embeddings} <- get_embeddings(idx, entry.file, summary, outline, contents),
         :ok <- Store.Entry.save(entry, summary, outline, embeddings) do
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
    res = idx.indexer_module.get_outline(idx.indexer, file, file_contents)
    progress_bar_update(:indexing)
    res
  end

  defp get_summary(idx, file, file_contents) do
    res = idx.indexer_module.get_summary(idx.indexer, file, file_contents)
    progress_bar_update(:indexing)
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

    result = idx.indexer_module.get_embeddings(idx.indexer, to_embed)
    progress_bar_update(:indexing)

    case result do
      {:error, reason} -> IO.inspect(reason)
      _ -> nil
    end

    result
  end

  # ----------------------------------------------------------------------------
  # UI interaction
  # ----------------------------------------------------------------------------
  defp spin(processing, func) do
    if quiet?() do
      UI.info(processing)
      {_msg, result} = func.()
      result
    else
      Spinner.run(func, processing)
    end
  end

  defp progress_bar_start(name, label, total) do
    if !quiet?() do
      Owl.ProgressBar.start(
        id: name,
        label: label,
        total: total,
        timer: true,
        absolute_values: true
      )
    end
  end

  defp progress_bar_update(name) do
    if !quiet?() do
      Owl.ProgressBar.inc(id: name)
      Owl.LiveScreen.await_render()
    end
  end

  defp start_in_progress_jobs_monitor(queue) do
    if quiet?() do
      Task.async(fn -> :ok end)
    else
      Owl.LiveScreen.add_block(:in_progress, state: "")

      Task.async(fn ->
        in_progress_jobs(queue)
        Owl.LiveScreen.update(:in_progress, "Indexing complete")
        Owl.LiveScreen.await_render()
      end)
    end
  end

  defp in_progress_jobs(queue) do
    unless Queue.is_idle(queue) do
      jobs =
        queue
        |> Queue.in_progress_jobs()
        |> Enum.map(&"- #{&1.rel_path}")
        |> Enum.join("\n")

      box =
        Owl.Box.new(jobs,
          title: "[ In Progress ]",
          border_style: :solid_rounded,
          horizontal_aling: :left,
          padding_x: 1
        )

      Owl.LiveScreen.update(:in_progress, box)

      Process.sleep(250)
      in_progress_jobs(queue)
    end
  end
end
