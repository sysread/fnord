defmodule Cmd.Indexer do
  @moduledoc """
  This module provides the functionality for the `index` sub-command.
  """

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
        nil ->
          settings = Settings.new()

          case get_root(settings, project) do
            {:ok, root} ->
              root

            {:error, :not_found} ->
              case Map.fetch(opts, :directory) do
                {:ok, nil} ->
                  raise """
                  Error: the project root was not found in the settings file.

                  This can happen when:
                    - the first index of a project
                    - the first index reindexing after moving the project directory
                    - the first index after the upgrade that made --dir optional

                  Re-run with --dir to specify the project root directory and update the settings file.
                  """

                {:ok, directory} ->
                  root = Path.absname(directory)
                  Settings.set_project(settings, project, %{"root" => root})
                  root
              end
          end

        root ->
          root
      end

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
    {:ok, tui} = Tui.start_link(idx.opts)

    if idx.reindex do
      # Delete entire project directory when --force-reindex is passed
      status_id = Tui.add_step("Deleting all data to force full reindexing", idx.project)
      Store.delete_project(idx.store)
      Tui.finish_step(status_id, :ok)
    else
      # Otherwise, just delete any files that no longer exist.
      status_id = Tui.add_step("Deleting missing files", idx.project)
      Store.delete_missing_files(idx.store, idx.root)
      Tui.finish_step(status_id, :ok)
    end

    scan_status_id = Tui.add_step("Scanning files", idx.root)

    {:ok, queue} =
      Queue.start_link(idx.concurrency, fn file ->
        process_file(idx, file)
      end)

    scanner =
      Scanner.new(idx.root, fn file ->
        Queue.queue(queue, file)
      end)

    total_files = Scanner.count_files(scanner)
    num_files = count_files_to_index(idx)

    Tui.finish_step(scan_status_id, :ok)

    index_status_id =
      Tui.add_step("Indexing", "#{num_files} / #{total_files} files in #{idx.root}")

    bs_status_id = Tui.add_step()

    Scanner.scan(scanner)

    Queue.shutdown(queue)
    Queue.join(queue)

    Tui.finish_step(index_status_id, :ok)
    Tui.finish_step(bs_status_id, :ok)
    Tui.stop(tui)
  end

  defp process_file(idx, file) do
    with {:ok, file_hash} <- get_file_hash(idx, file) do
      file_contents = File.read!(file)

      with {:ok, summary} <- get_summary(idx, file, file_contents),
           {:ok, outline} <- get_outline(idx, file, file_contents),
           {:ok, embeddings} <- get_embeddings(idx, file, summary, outline, file_contents) do
        Store.put(idx.store, file, file_hash, summary, outline, embeddings)
      else
        {:error, reason} -> Tui.warn("Error processing file #{file}", reason)
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
    idx.ai_module.get_outline(idx.ai, file, file_contents)
  end

  defp get_summary(idx, file, file_contents) do
    idx.ai_module.get_summary(idx.ai, file, file_contents)
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
        {:ok, embeddings}

      {:error, %OpenaiEx.Error{message: "Request timed out."}} ->
        if attempt < 3 do
          Tui.warn("request to index file timed out, retrying", "attempt #{attempt + 1}/3")
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
end
