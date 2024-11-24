defmodule Cmd.Indexer do
  @moduledoc """
  This module provides the functionality for the `index` sub-command.
  """

  require Logger

  defstruct [
    :opts,
    :project,
    :root,
    :store,
    :concurrency,
    :reindex,
    :ai_module,
    :ai,
    :quiet
  ]

  @doc """
  Create a new `Indexer` struct.
  """
  def new(opts, ai_module \\ AI) do
    concurrency = Map.get(opts, :concurrency, 1)
    reindex = Map.get(opts, :reindex, false)
    quiet = Map.get(opts, :quiet, false)
    project = opts.project

    root =
      case Map.get(opts, :directory, nil) do
        root when is_binary(root) ->
          Path.absname(root)

        nil ->
          settings = Settings.new()

          case get_root(settings, project) do
            {:ok, root} ->
              root

            {:error, :not_found} ->
              raise """
              Error: the project root was not found in the settings file.

              This can happen under the following circumstances:
                - the first index of a project
                - the first index reindexing after moving the project directory
                - the first index after the upgrade that made --dir optional

              Re-run with --dir to specify the project root directory and update the settings file.
              """
          end
      end

    Settings.new()
    |> Settings.set_project(project, %{"root" => root})

    idx =
      %__MODULE__{
        opts: opts,
        project: opts.project,
        root: root,
        store: Store.new(project),
        concurrency: concurrency,
        reindex: reindex,
        ai_module: ai_module,
        ai: ai_module.new(),
        quiet: quiet
      }

    idx
  end

  # Retrieves the project root from settings. If the project is not yet found
  # in settings or it _is_ but the value of `"root"` is `nil`, it will return
  # an error.
  defp get_root(settings, project) do
    with {:ok, info} <- Settings.get_project(settings, project),
         {:ok, root} <- Map.fetch(info, "root") do
      case root do
        nil -> {:error, :not_found}
        _ -> {:ok, Path.absname(root)}
      end
    end
  end

  @doc """
  Run the indexing process using the given `Indexer` struct. If `force_reindex`
  is `true`, the project will be deleted and reindexed from scratch.
  """
  def run(idx) do
    if idx.reindex do
      # Delete entire project directory when --force-reindex is passed
      msg = "Deleting all embeddings to force full reindexing of #{idx.project}"

      spin(idx, msg, fn ->
        {"Burned it all to the ground", Store.delete_project(idx.store)}
      end)
    else
      # Otherwise, just delete any files that no longer exist.
      msg = "Deleting missing files from #{idx.project}"

      spin(idx, msg, fn ->
        {"Deleted missing files", Store.delete_missing_files(idx.store, idx.root)}
      end)
    end

    {:ok, queue} =
      Queue.start_link(idx.concurrency, fn file ->
        process_file(idx, file)
      end)

    scanner =
      Scanner.new(idx.root, fn file ->
        Queue.queue(queue, file)
      end)

    count =
      spin(idx, "Scanning project files", fn ->
        num_files = count_files_to_index(idx)
        total_files = Scanner.count_files(scanner)
        msg = "Indexing #{num_files} of #{total_files} total files"
        {msg, num_files}
      end)

    spin(idx, "Indexing #{idx.project}", fn ->
      # count * 3 for each step in indexing a file (summary, outline, embeddings)
      progress_bar_start(idx, :indexing, "tasks", count * 3)

      Scanner.scan(scanner)

      Queue.shutdown(queue)
      Queue.join(queue)

      progress_bar_end(idx)

      {"All tasks complete", :ok}
    end)
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
      case get_file_hash(idx, file) do
        {:ok, _} -> acc + 1
        {:error, :unchanged} -> acc
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
    res = idx.ai_module.get_outline(idx.ai, file, file_contents)
    progress_bar_update(idx, :indexing)
    res
  end

  defp get_summary(idx, file, file_contents) do
    res = idx.ai_module.get_summary(idx.ai, idx.project, file, file_contents)
    progress_bar_update(idx, :indexing)
    res
  end

  defp get_embeddings(idx, file, summary, outline, file_contents, attempt \\ 0) do
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

    idx.ai_module.get_embeddings(idx.ai, to_embed)
    |> case do
      {:ok, embeddings} ->
        progress_bar_update(idx, :indexing)
        {:ok, embeddings}

      {:error, %OpenaiEx.Error{message: "Request timed out."}} ->
        if attempt < 3 do
          UI.warn("request to index file timed out, retrying", "attempt #{attempt + 1}/3")
          get_embeddings(idx, file, summary, outline, file_contents, attempt + 1)
        else
          {:error, "request to index file timed out after 3 attempts"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sha256(file_path) do
    case File.read(file_path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, reason} -> {:error, reason}
    end
  end

  # -----------------------------------------------------------------------------
  # UI interaction
  # -----------------------------------------------------------------------------
  defp spin(idx, processing, func) do
    if idx.quiet do
      {_msg, result} = func.()
      result
    else
      Spinner.run(func, processing)
    end
  end

  defp progress_bar_start(idx, name, label, total) do
    if !idx.quiet do
      Owl.ProgressBar.start(
        id: name,
        label: label,
        total: total,
        timer: true,
        absolute_values: true
      )
    end
  end

  defp progress_bar_end(idx) do
    if !idx.quiet do
      Owl.LiveScreen.await_render()
    end
  end

  defp progress_bar_update(idx, name) do
    if !idx.quiet do
      Owl.ProgressBar.inc(id: name)
    end
  end
end
