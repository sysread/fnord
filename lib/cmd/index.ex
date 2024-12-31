defmodule Cmd.Index do
  @behaviour Cmd

  defstruct [
    :opts,
    :indexer_module,
    :indexer,
    :project
  ]

  @impl Cmd
  def spec do
    [
      index: [
        name: "index",
        about: "Index a project",
        options: [
          directory: [
            value_name: "DIR",
            long: "--dir",
            short: "-d",
            help:
              "Directory to index (required for first index or reindex after moving the project)",
            required: false
          ],
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ],
          workers: [
            value_name: "WORKERS",
            long: "--workers",
            short: "-w",
            help: "Number of concurrent workers to use",
            parser: :integer,
            default: Cmd.default_workers()
          ],
          exclude: [
            value_name: "FILE",
            long: "--exclude",
            short: "-x",
            help:
              "Exclude a file, directory, or glob from being indexed; this is stored in the project's configuration and used on subsequent indexes",
            multiple: true
          ]
        ],
        flags: [
          defrag_notes: [
            long: "--defrag-notes",
            short: "-D",
            help: "Consolidate saved notes",
            default: false
          ],
          reindex: [
            long: "--reindex",
            short: "-r",
            help: "Reindex the project",
            default: false
          ],
          quiet: [
            long: "--quiet",
            short: "-Q",
            help: "Suppress interactive output; automatically enabled when executed in a pipe",
            required: false,
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts) do
    opts
    |> new()
    |> perform_task()
  end

  def perform_task(idx) do
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

    index_project(idx)

    if Map.get(idx.opts, :defrag_notes, false) do
      defrag_notes(idx)
    end
  end

  def new(opts, indexer \\ Indexer) do
    with {:ok, project_name} <- Map.fetch(opts, :project) do
      Application.put_env(:fnord, :project, project_name)
    end

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

  # ----------------------------------------------------------------------------
  # Options
  # ----------------------------------------------------------------------------
  defp quiet?(), do: Application.get_env(:fnord, :quiet)
  defp reindex?(idx), do: Map.get(idx.opts, :reindex, false)

  # -----------------------------------------------------------------------------
  # Verifying saved notes
  # -----------------------------------------------------------------------------
  defp defrag_notes(idx) do
    notes =
      idx.project
      |> Store.Note.list_notes()
      |> Enum.reduce([], fn note, acc ->
        with {:ok, text} <- Store.Note.read_note(note) do
          [text | acc]
        else
          _ -> acc
        end
      end)
      |> Enum.reverse()

    consolidate_saved_notes(idx, notes)
  end

  defp consolidate_saved_notes(_idx, []) do
    UI.warn("Verifying prior research: nothing to do")
  end

  defp consolidate_saved_notes(idx, original_notes) do
    total = Enum.count(original_notes)
    UI.report_step("Consolidating and fact-checking prior research", "Analyzing #{total} notes")

    AI.new()
    |> AI.Agent.NotesConsolidator.get_response(%{notes: original_notes})
    |> case do
      {:ok, notes} ->
        IO.puts("# Consolidated Notes")

        notes = String.split(notes, "\n")

        notes
        |> Enum.each(fn text ->
          IO.puts("- #{text}")
        end)

        original_count = Enum.count(original_notes)
        new_count = Enum.count(notes)

        difference =
          ((new_count - original_count) / original_count * 100)
          |> Float.round(0)
          |> trunc()
          |> abs()

        IO.puts("""

        There is a #{difference}% change in note count:
          * Original: #{original_count}
          *  Updated: #{new_count}

        """)

        if difference > 25 do
          msg =
            [
              :red,
              """
              >>> WARNING! <<<
              ! The consolidated notes differ by #{difference}% from the original notes.
              ! Check the consolidated notes carefully before proceeding.
              """,
              :reset
            ]
            |> IO.ANSI.format()

          IO.puts(msg)
        end

        if UI.confirm("Replace your saved notes with the consolidated list?") do
          spin("Saving consolidated notes", fn ->
            {:ok, queue} =
              Queue.start_link(fn text ->
                idx.project
                |> Store.Note.new()
                |> Store.Note.write(text)
              end)

            UI.report_step("Clearing old notes")
            Store.Note.reset_project_notes(idx.project)

            # queue files
            Enum.each(notes, &Queue.queue(queue, &1))

            # wait on queue to complete
            Queue.shutdown(queue)
            Queue.join(queue)

            {"#{new_count} notes saved", :ok}
          end)

          UI.info("Notes saved.")
        else
          UI.warn("Consolidation of notes aborted at user request")
        end

      error ->
        UI.warn("Error consolidating notes", inspect(error))
    end
  end

  # ----------------------------------------------------------------------------
  # Indexing process
  # ----------------------------------------------------------------------------
  defp index_project(idx) do
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

        {"All file indexing tasks complete", :ok}
      end)
    end
  end

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
