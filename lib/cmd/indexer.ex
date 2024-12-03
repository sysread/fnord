defmodule Cmd.Indexer do
  @moduledoc """
  This module provides the functionality for the `index` sub-command.
  """

  defstruct [
    :opts,
    :indexer_module,
    :indexer,
    :root,
    :store,
    :reindex,
    :exclude,
    :expanded_exclude
  ]

  @doc """
  Create a new `Indexer` struct.
  """
  def new(opts, indexer \\ Indexer) do
    reindex = Map.get(opts, :reindex, false)
    settings = get_settings(opts)

    if Map.get(settings, "root") == nil do
      raise """
      Error: the project root was not found in the settings file.

      This can happen under the following circumstances:
        - the first index of a project
        - the first index reindexing after moving the project directory
        - the first index after the upgrade that made --dir optional

      Re-run with --dir to specify the project root directory and update the settings file.
      """
    end

    exclude = Map.get(settings, "exclude")
    expanded_exclude = expand_excludes(exclude)

    %__MODULE__{
      opts: opts,
      indexer_module: indexer,
      indexer: indexer.new(),
      store: Store.new(),
      reindex: reindex,
      root: Map.get(settings, "root"),
      exclude: exclude || [],
      expanded_exclude: expanded_exclude || []
    }
  end

  # Retrieves project settings from the config file, then overrides any values
  # that were explicitly set in the command line invocation.
  defp get_settings(opts) do
    settings = Settings.new()

    # Get the project's current settings
    project =
      Settings.get_project(settings)
      |> case do
        {:ok, project_settings} -> project_settings
        {:error, :not_found} -> %{}
      end

    # ---------------------------------------------------------------------------
    # The presence of exclude_patterns means they have an old settings file.
    # We removed that in 0.4.37. If they have it, try to fix it.
    #
    # The old `exclude` was the expanded patterns, and `exclude_patterns` was
    # the user's -x selections. We need to replace `exclude` with the contents
    # of `exclude_patterns` and then delete `exclude_patterns`, which is
    # deprecated.
    # ---------------------------------------------------------------------------
    project =
      if Map.has_key?(project, "exclude_patterns") do
        project = Map.put(project, "exclude", project["exclude_patterns"])
        project = Map.delete(project, "exclude_patterns")
        Settings.set_project(settings, project)
      else
        project
      end

    # Update the root if provided in user options
    project =
      case Map.get(opts, :directory) do
        nil -> project
        root -> Map.put(project, "root", Path.absname(root))
      end

    # Update the exclusions if provided in user options
    project =
      case Map.get(opts, :exclude) do
        [] -> project
        exclude -> Map.put(project, "exclude", exclude)
      end

    # Save the updated settings and return the project map
    Settings.set_project(settings, project)
  end

  @doc """
  Run the indexing process using the given `Indexer` struct. If `force_reindex`
  is `true`, the project will be deleted and reindexed from scratch.
  """
  def run(idx) do
    project = Application.get_env(:fnord, :project)
    UI.info("Indexing", project)
    UI.info("Root", idx.root)
    UI.info("Excluding", Enum.join(idx.exclude, " | "))

    if idx.reindex do
      Store.delete_project(idx.store)
      UI.report_step("Burned all of the old data to the ground to force a full reindex!")
    else
      # Otherwise, just delete any files that no longer exist.
      Store.delete_missing_files(idx.store, idx.root)
      UI.report_step("Deleted missing and newly excluded files")
    end

    {:ok, queue} = Queue.start_link(&process_file(idx, &1))

    scanner =
      Scanner.new(idx.root, fn file ->
        if file not in idx.expanded_exclude do
          Queue.queue(queue, file)
        end
      end)

    count =
      spin("Scanning project files", fn ->
        num_files = count_files_to_index(idx)
        total_files = Scanner.count_files(scanner)
        msg = "Indexing #{num_files} of #{total_files} total files"
        {msg, num_files}
      end)

    if count == 0 do
      UI.warn("No files to index in #{project}")
    else
      spin("Indexing #{project}", fn ->
        # count * 3 for each step in indexing a file (summary, outline, embeddings)
        progress_bar_start(:indexing, "tasks", count * 3)

        Scanner.scan(scanner)

        Queue.shutdown(queue)
        Queue.join(queue)

        progress_bar_end()

        {"All tasks complete", :ok}
      end)
    end
  end

  # -----------------------------------------------------------------------------
  # Indexing process
  # -----------------------------------------------------------------------------
  defp process_file(idx, file) do
    with {:ok, file_hash} <- get_file_hash(idx, file) do
      file_contents = File.read!(file)

      with {:ok, summary} <- get_summary(idx, file, file_contents),
           {:ok, outline} <- get_outline(idx, file, file_contents),
           {:ok, embeddings} <- get_embeddings(idx, file, summary, outline, file_contents) do
        Store.put(idx.store, file, file_hash, summary, outline, embeddings)
      else
        {:error, reason} -> UI.warn("Error processing file #{file}", reason)
      end
    end
  end

  defp count_files_to_index(idx) do
    idx.root
    |> Scanner.new(fn _ -> nil end)
    |> Scanner.reduce(0, nil, fn file, acc ->
      if file in idx.expanded_exclude do
        acc
      else
        case get_file_hash(idx, file) do
          {:ok, _} -> acc + 1
          {:error, :unchanged} -> acc
        end
      end
    end)
  end

  defp get_file_hash(idx, file) do
    # Files that are missing or have missing indexes must be reindexed.
    cond do
      !Store.has_summary?(idx.store, file) ->
        {:ok, nil}

      !Store.has_outline?(idx.store, file) ->
        {:ok, nil}

      !Store.has_embeddings?(idx.store, file) ->
        {:ok, nil}

      true ->
        existing_hash = Store.get_hash(idx.store, file)
        file_hash = sha256(file)

        if is_nil(existing_hash) or existing_hash != file_hash do
          {:ok, file_hash}
        else
          {:error, :unchanged}
        end
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

  defp sha256(file_path) do
    case File.read(file_path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, reason} -> {:error, reason}
    end
  end

  # -----------------------------------------------------------------------------
  # Helper functions
  # -----------------------------------------------------------------------------
  defp expand_excludes(nil), do: nil

  defp expand_excludes(excludes) do
    excludes
    |> Enum.flat_map(fn exclude ->
      cond do
        # If it's a directory, expand recursively to all files and directories
        File.dir?(exclude) -> Path.wildcard(Path.join(exclude, "**/*"), match_dot: true)
        # If it's a specific file, expand to its absolute path
        File.exists?(exclude) -> [Path.absname(exclude)]
        # Assume it's a glob pattern and expand it
        true -> Path.wildcard(exclude, match_dot: true)
      end
    end)
    # Filter out directories and non-existent files
    |> Enum.filter(&File.regular?/1)
    # Convert everything to absolute paths
    |> Enum.map(&Path.absname/1)
  end

  # -----------------------------------------------------------------------------
  # UI interaction
  # -----------------------------------------------------------------------------
  defp quiet?(), do: Application.get_env(:fnord, :quiet)

  defp spin(processing, func) do
    if quiet?() do
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

  defp progress_bar_end() do
    if !quiet?() do
      Owl.LiveScreen.await_render()
    end
  end

  defp progress_bar_update(name) do
    if !quiet?() do
      Owl.ProgressBar.inc(id: name)
      Owl.LiveScreen.await_render()
    end
  end
end
