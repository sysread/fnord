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
    case new(opts) do
      {:ok, idx} ->
        perform_task({:ok, idx})
        maybe_prime_notes(idx)

      {:error, :directory_required} ->
        UI.fatal("Error: -d | --directory is required")

      other ->
        perform_task(other)
    end
  end

  @doc """
  This function is used to run the indexing process as a tool call from within
  the `file_reindex_tool` tool.
  """
  def run_as_tool_call(opts) do
    # Ensure we restore the global `:quiet` flag after indexing so that
    # UI output returns to its previous formatting mode.
    original_quiet = Services.Globals.get_env(:fnord, :quiet, false)

    try do
      if opts[:quiet] do
        Settings.set_quiet(true)
      end

      with {:ok, idx} <- new(opts) do
        idx
        |> Map.put(:has_notes?, true)
        |> then(&perform_task({:ok, &1}))
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
      # Determine whether to persist project root/exclude
      settings = Settings.new()
      orig_data = Settings.get_project_data(settings, project.name) || %{}
      orig_root = Map.get(orig_data, "root")
      # Persist only on first index, explicit --dir (non-empty), or when exclude changes
      user_dir_val = Map.get(opts, :directory)

      user_provided_dir? =
        case user_dir_val do
          nil -> false
          "" -> false
          _ -> true
        end

      persist? =
        user_provided_dir? or Map.has_key?(opts, :exclude) or is_nil(orig_root)

      # If the user provided a directory, use that expanded value; otherwise root
      project =
        project
        |> (fn project ->
              if persist? do
                Store.Project.save_settings(project, root, exclude)
              else
                project
              end
            end).()
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
        %__MODULE__{
          opts: opts,
          indexer: Indexer.impl(),
          project: project
        }
        |> maybe_set_has_notes()
        |> then(&{:ok, &1})
      end
    end
  end

  defp maybe_set_has_notes(%{opts: %{has_notes?: has_notes?}} = idx)
       when is_boolean(has_notes?) do
    %{idx | has_notes?: has_notes?}
  end

  defp maybe_set_has_notes(idx) do
    Store.Project.Notes.read()
    |> case do
      {:ok, _} -> Map.put(idx, :has_notes?, true)
      {:error, :no_notes} -> Map.put(idx, :has_notes?, false)
    end
  end

  # ----------------------------------------------------------------------------
  # Indexing process
  # ----------------------------------------------------------------------------
  defp confirm_root_changed?(project, opts) do
    yes = Map.get(opts, :yes, false)
    user_dir_val = Map.get(opts, :directory)

    user_provided_dir? =
      case user_dir_val do
        nil -> false
        "" -> false
        _ -> true
      end

    new_directory =
      case user_dir_val do
        nil -> project.source_root
        dir -> Path.expand(dir)
      end

    cond do
      # If the user has passed --yes, assume confirmation. If we still don't
      # have a directory, default to the current working directory.
      yes ->
        {:ok, ensure_dir_for_yes(new_directory)}

      # When there is no project.root and the user did not explicitly pass
      # --dir, prompt whether to use the current directory as the project root.
      is_nil(project.source_root) and not user_provided_dir? ->
        prompt = """
        No directory specified. Would you like to use the current directory as the project root?

        Current directory: #{File.cwd!()}
        """

        UI.confirm(prompt, false)
        |> case do
          true -> {:ok, File.cwd!()}
          false -> {:error, :directory_required}
        end

      # If the project has no source root but the user explicitly supplied --dir,
      # just use that value (it will be validated later).
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

  # Returns the provided directory if not nil, otherwise uses the current
  # working directory.
  defp ensure_dir_for_yes(nil) do
    File.cwd!()
  end

  defp ensure_dir_for_yes(dir) do
    dir
  end

  defp reindex?(idx), do: Map.get(idx.opts, :reindex, false)

  def index_project(idx) do
    # Ensure legacy entries are migrated to relative-path scheme before indexing
    Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(idx.project)

    status =
      idx
      |> maybe_reindex()
      |> scan_project()
      |> delete_entries()
      |> index_entries()

    # Index conversations after file entries
    index_conversations(idx.project)

    status
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

  @spec index_conversations(Store.Project.t()) :: :ok
  defp index_conversations(project) do
    %{new: new, stale: stale, deleted: deleted} =
      Store.Project.ConversationIndex.index_status(project)

    UI.spin("Deleting missing conversations from index", fn ->
      Enum.each(deleted, &Store.Project.ConversationIndex.delete(project, &1))
      {"Deleted #{Enum.count(deleted)} conversation(s) from the index", :ok}
    end)

    conversations = new ++ stale
    count = Enum.count(conversations)

    if count == 0 do
      UI.warn("No conversations to index")
      :ok
    else
      UI.spin("Indexing #{count} conversation(s)", fn ->
        # Split conversations into chunks and process each chunk
        # concurrently. Util.async_stream defaults to
        # System.schedulers_online() for concurrency.
        partitions_count = 4
        chunk_size = div(count + partitions_count - 1, partitions_count)
        partitions = Enum.chunk_every(conversations, chunk_size)

        tasks =
          partitions
          |> Enum.map(fn part ->
            Services.Globals.Spawn.async(fn ->
              part
              |> Util.async_stream(fn convo -> process_conversation(project, convo) end)
              |> Enum.to_list()
            end)
          end)

        # Wait for all partitions to finish
        Enum.each(tasks, fn t -> Task.await(t, :infinity) end)

        {"All conversation indexing tasks complete", :ok}
      end)
    end
  end

  defp process_conversation(project, convo) do
    with {:ok, data} <- Store.Project.Conversation.read(convo),
         {:ok, json} <- Jason.encode(%{"messages" => data.messages}),
         {:ok, embeddings} <- Indexer.impl().get_embeddings(json),
         :ok <-
           Store.Project.ConversationIndex.write_embeddings(
             project,
             convo.id,
             embeddings,
             Map.merge(data.metadata, %{
               "conversation_id" => convo.id,
               "last_indexed_ts" => DateTime.to_unix(data.timestamp),
               "message_count" => length(data.messages)
             })
           ) do
      :ok
    else
      {:error, reason} ->
        UI.warn(
          "Error processing conversation #{convo.id}",
          inspect(reason, pretty: true, limit: :infinity)
        )

        :error
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
      if Services.Globals.get_env(:fnord, :quiet) do
        UI.info("✓ #{entry.file}")
      end

      :ok
    else
      {:error, reason} ->
        UI.warn("Error processing #{entry.file}", inspect(reason, pretty: true, limit: :infinity))
    end
  end

  defp get_derivatives(file, file_contents) do
    summary_task = Services.Globals.Spawn.async(fn -> get_summary(file, file_contents) end)
    outline_task = Services.Globals.Spawn.async(fn -> get_outline(file, file_contents) end)

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

  defp maybe_prime_notes(%{opts: %{quiet: true}} = idx), do: idx
  defp maybe_prime_notes(%{has_notes?: true} = idx), do: idx

  defp maybe_prime_notes(idx) do
    if UI.confirm(@prime_prompt, false) do
      Cmd.Prime.run(idx.opts, [], [])
    end
  end
end
