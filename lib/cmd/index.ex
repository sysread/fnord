defmodule Cmd.Index do
  defstruct [
    :opts,
    :indexer,
    :project,
    :has_notes?
  ]

  @type t :: %__MODULE__{}

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      index: [
        name: "index",
        about: "Index a project",
        options: [
          project: Cmd.project_arg(),
          workers: Cmd.workers_arg(),
          directory: [
            value_name: "DIR",
            long: "--dir",
            short: "-d",
            help:
              "Directory to index (required for first index or reindex after moving the project)",
            required: false
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
          ],
          yes: [
            long: "--yes",
            short: "-y",
            help: "Assume 'yes' to all prompts",
            required: false,
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    with {:ok, idx} <- new(opts) do
      perform_task({:ok, idx})
      maybe_prime_notes(idx)
    end
  end

  @doc """
  This function is used to run the indexing process as a tool call from within
  the `file_reindex_tool` tool.
  """
  def run_as_tool_call(opts) do
    # Ensure we restore the global `:quiet` flag after indexing so that
    # UI output returns to its previous formatting mode.
    original_quiet = Application.get_env(:fnord, :quiet, false)

    try do
      if opts[:quiet] do
        Settings.set_quiet(true)
      end

      with {:ok, idx} <- new(opts) do
        perform_task({:ok, idx})
      end
    after
      # Restore previous quiet setting regardless of indexing outcome
      Settings.set_quiet(original_quiet)
    end
  end

  # -----------------------------------------------------------------------------
  # Task execution
  # -----------------------------------------------------------------------------
  def perform_task({:error, :user_cancelled}) do
    UI.warn("Indexing cancelled by user")
    {:error, :user_cancelled}
  end

  def perform_task({:ok, idx}) do
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

    try do
      index_project(idx)
    rescue
      e ->
        UI.error("An error occurred during indexing", Exception.message(e))
        UI.info("Recovery", "Restarting the indexing process will pick up where it left off.")
        {:error, e}
    end
  end

  def perform_task(other) do
    other
  end

  def new(opts) do
    with {:ok, project} <- Store.get_project(),
         {:ok, root} <- confirm_root_changed?(project, opts),
         {:ok, exclude} <- confirm_exclude_changed?(project, opts, root) do
      project =
        project
        |> Store.Project.save_settings(root, exclude)
        |> Store.Project.make_default_for_session()

      if is_nil(project.source_root) do
        {:error,
         """
         Error: the project root was not found in the settings file.

         This can happen under the following circumstances:
           - the first index of a project
           - the first index reindexing after moving the project directory
           - the first index after the upgrade that made --dir optional
         """}
      else
        has_notes? =
          Store.Project.Notes.read()
          |> case do
            {:ok, _} -> true
            {:error, :no_notes} -> false
          end

        {:ok,
         %__MODULE__{
           opts: opts,
           indexer: Indexer.impl(),
           project: project,
           has_notes?: has_notes?
         }}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Indexing process
  # ----------------------------------------------------------------------------
  defp confirm_root_changed?(project, opts) do
    yes = Map.get(opts, :yes, false)

    new_directory =
      Map.get(opts, :directory)
      |> case do
        nil -> project.source_root
        dir -> Path.expand(dir)
      end

    cond do
      yes ->
        {:ok, new_directory}

      is_nil(project.source_root) ->
        {:ok, new_directory}

      new_directory == project.source_root ->
        {:ok, new_directory}

      true ->
        UI.confirm(
          """
          You are about to index the project in a different directory.

          From: #{project.source_root}
            To: #{new_directory}

          This will overwrite the existing index. Do you want to continue?
          """,
          yes
        )
        |> case do
          true -> {:ok, new_directory}
          false -> {:error, :user_cancelled}
        end
    end
  end

  defp confirm_exclude_changed?(project, opts, root) do
    yes = Map.get(opts, :yes, false)

    new_exclude =
      Map.get(opts, :exclude)
      |> case do
        nil ->
          project.exclude

        [] ->
          project.exclude

        exclude ->
          Enum.map(exclude, fn path ->
            path
            |> Path.expand()
            |> Path.relative_to(root)
          end)
      end

    cond do
      yes ->
        {:ok, new_exclude}

      project.exclude == [] ->
        {:ok, new_exclude}

      new_exclude == project.exclude ->
        {:ok, new_exclude}

      true ->
        UI.confirm(
          """
          You are about to change the excluded paths for the project.

          From: #{Enum.join(project.exclude || [], ", ")}
            To: #{Enum.join(new_exclude, ", ")}

          This will overwrite the existing exclusions. Do you want to continue?
          """,
          yes
        )
        |> case do
          true -> {:ok, new_exclude}
          false -> {:error, :user_cancelled}
        end
    end
  end

  defp reindex?(idx), do: Map.get(idx.opts, :reindex, false)

  def index_project(idx) do
    idx
    |> maybe_reindex()
    |> scan_project()
    |> delete_entries()
    |> index_entries()
  end

  @spec scan_project(Store.Project.t()) :: Store.Project.index_status()
  defp scan_project(project) do
    UI.spin("Scanning the project directory", fn ->
      status = Store.Project.index_status(project)

      msg = """
      Scan Results:
      - Stale:   #{Enum.count(status.stale)}
      - New:     #{Enum.count(status.new)}
      - Deleted: #{Enum.count(status.deleted)}
      """

      {msg, status}
    end)
  end

  @spec maybe_reindex(t) :: Store.Project.t()
  defp maybe_reindex(%{project: project} = idx) do
    if reindex?(idx) do
      Store.Project.delete(project)
      UI.report_step("Burned all of the old data to the ground to force a full reindex!")
    end

    project
  end

  defp delete_entries(%{deleted: deleted} = status) do
    UI.spin("Deleting missing and newly excluded files from index", fn ->
      Enum.each(deleted, &Store.Project.Entry.delete/1)
      count = Enum.count(deleted)
      {"Deleted #{count} file(s) from the index", status}
    end)
  end

  @spec index_entries(Store.Project.index_status()) :: Store.Project.index_status()
  defp index_entries(%{new: new, stale: stale} = status) do
    files_to_index = new ++ stale
    count = Enum.count(files_to_index)

    if count == 0 do
      UI.warn("No files to index")
    else
      UI.spin("Indexing #{count} file(s)", fn ->
        files_to_index
        |> UI.async_stream(&process_entry(&1), "Indexing")
        |> Enum.to_list()

        {"All file indexing tasks complete", :ok}
      end)
    end

    status
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
        UI.info("✓ #{entry.file}")
      end

      :ok
    else
      {:error, reason} ->
        UI.warn("Error processing #{entry.file}", inspect(reason, pretty: true, limit: :infinity))
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

  @prime_prompt """
  No research has been done yet for this project.
  Fnord uses notes from prior research to improve the quality of its answers.
  Would you like to prime the project with some initial research?
  """

  defp maybe_prime_notes(%{opts: %{quiet: false}} = idx), do: idx
  defp maybe_prime_notes(%{has_notes?: true} = idx), do: idx

  defp maybe_prime_notes(idx) do
    if UI.confirm(@prime_prompt, false) do
      Cmd.Prime.run(idx.opts, [], [])
    end
  end
end
