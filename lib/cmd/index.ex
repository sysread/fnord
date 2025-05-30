defmodule Cmd.Index do
  @behaviour Cmd

  defstruct [
    :opts,
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
            help: "Limits the number of concurrent OpenAI requests",
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
          reindex: [
            long: "--reindex",
            short: "-r",
            help: "Reindex the project",
            default: false
          ],
          quiet: [
            long: "--quiet",
            short: "-Q",
            help: "Suppress the progress bar, instead logging files as they are indexed",
            required: false,
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    opts
    |> new()
    |> perform_task()
  end

  def perform_task(idx) do
    UI.info("Project", idx.project.name)
    UI.info("Workers", Application.get_env(:fnord, :workers) |> to_string())
    UI.info("   Root", idx.project.source_root)

    UI.info(
      "Exclude",
      case idx.project.exclude do
        nil -> "None"
        globs -> Enum.join(globs, " | ")
      end
    )

    index_project(idx)
  end

  def new(opts) do
    project_name = Map.get(opts, :project)

    project =
      project_name
      |> Store.get_project()
      |> Store.Project.save_settings(
        Map.get(opts, :directory),
        Map.get(opts, :exclude)
      )
      |> Store.Project.make_default_for_session()

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
      indexer: Indexer.impl(),
      project: project
    }
  end

  # ----------------------------------------------------------------------------
  # Indexing process
  # ----------------------------------------------------------------------------
  defp reindex?(idx), do: Map.get(idx.opts, :reindex, false)

  def index_project(%{project: project} = idx) do
    project =
      if reindex?(idx) do
        Store.Project.delete(project)
        UI.report_step("Burned all of the old data to the ground to force a full reindex!")
        project
      else
        UI.spin("Deleting missing and newly excluded files from index", fn ->
          {project, deleted} = Store.Project.delete_missing_files(project)
          count = Enum.count(deleted)
          {"Deleted #{count} file(s) from the index", project}
        end)
      end

    {project, all_files} =
      UI.spin("Scanning project files", fn ->
        {project, files} = Store.Project.source_files(project)
        count = files |> Enum.to_list() |> Enum.count()
        {"There are #{count} indexable file(s) in project", {project, files}}
      end)

    stale_files =
      UI.spin("Identifying stale files", fn ->
        files =
          all_files
          |> Stream.filter(&Store.Project.Entry.is_stale?/1)
          |> Enum.to_list()

        {"Identified #{Enum.count(files)} stale file(s) to index", files}
      end)

    total = Enum.count(all_files)
    count = Enum.count(stale_files)

    if count == 0 do
      UI.warn("No files to index in #{project.name}")
    else
      UI.spin("Indexing #{count} / #{total} files", fn ->
        stale_files
        |> UI.async_stream(&process_entry(&1), "Indexing")
        |> Enum.to_list()

        {"All file indexing tasks complete", :ok}
      end)
    end
  end

  defp process_entry(entry) do
    with {:ok, contents} <- Store.Project.Entry.read_source_file(entry),
         {:ok, summary, outline} <- get_derivatives(entry.file, contents),
         {:ok, embeddings} <- get_embeddings(entry.file, summary, outline, contents),
         :ok <- Store.Project.Entry.save(entry, summary, outline, embeddings) do
      # If :quiet is true, the progress bar will be absent, so instead, we'll
      # emit debug logs to stderr. The user can control whether those are
      # displayed by setting LOGGER_LEVEL.
      if Application.get_env(:fnord, :quiet) do
        UI.debug("✓ #{entry.file}")
      end

      :ok
    else
      {:error, reason} ->
        UI.warn("Error processing #{entry.file}", inspect(reason))
    end
  end

  defp get_derivatives(file, file_contents) do
    summary_task = Task.async(fn -> get_summary(file, file_contents) end)
    outline_task = Task.async(fn -> get_outline(file, file_contents) end)

    with {:ok, summary} <- Task.await(summary_task, :infinity),
         {:ok, outline} <- Task.await(outline_task, :infinity) do
      {:ok, summary, outline}
    end
  end

  defp get_outline(file, file_contents) do
    Indexer.impl().get_outline(file, file_contents)
  end

  defp get_summary(file, file_contents) do
    Indexer.impl().get_summary(file, file_contents)
  end

  defp get_embeddings(file, summary, outline, file_contents) do
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

    Indexer.impl().get_embeddings(to_embed)
  end
end
