defmodule Indexer do
  @moduledoc """
  This module provides the functionality for the `index` and `delete`
  sub-commands.
  """

  defstruct [
    :project,
    :root,
    :store,
    :concurrency,
    :reindex,
    :ai_module,
    :ai
  ]

  @doc """
  Create a new `Indexer` struct.
  """
  def new(opts, ai_module \\ AI) do
    concurrency = Map.get(opts, :concurrency, 1)
    reindex = Map.get(opts, :reindex, false)

    idx = %Indexer{
      project: opts.project,
      root: opts.directory,
      store: Store.new(opts.project),
      concurrency: concurrency,
      reindex: reindex,
      ai_module: ai_module,
      ai: ai_module.new()
    }

    idx
  end

  @doc """
  Run the indexing process using the given `Indexer` struct. If `force_reindex`
  is `true`, the project will be deleted and reindexed from scratch.
  """
  def run(idx) do
    if idx.reindex do
      # When --force-reindex is passed, delete the project completely and start
      # from scratch.
      Owl.Spinner.run(
        fn ->
          Store.delete_project(idx.store)
        end,
        labels: [
          processing: "Deleting all embeddings to force full reindexing of #{idx.project}",
          ok: "Deleted all embeddings to force full reindexing of #{idx.project}"
        ]
      )
    else
      # Otherwise, just delete any files that no longer exist.
      Owl.Spinner.run(
        fn ->
          Store.delete_missing_files(idx.store, idx.root)
        end,
        labels: [
          processing: "Deleting missing files from #{idx.project}",
          ok: "Deleted missing files from #{idx.project}"
        ]
      )
    end

    Owl.Spinner.run(
      fn ->
        {:ok, queue} =
          Queue.start_link(idx.concurrency, fn file ->
            process_file(idx, file)
            Owl.ProgressBar.inc(id: :indexing)
          end)

        scanner = Scanner.new(idx.root, fn file -> Queue.queue(queue, file) end)
        num_files = Scanner.count_files(scanner)

        Owl.ProgressBar.start(id: :indexing, label: "Indexing", total: num_files + 1)

        Scanner.scan(scanner)

        Queue.shutdown(queue)
        Queue.join(queue)

        Owl.LiveScreen.await_render()

        IO.puts("All tasks complete")
      end,
      labels: [
        processing: "Indexing files in #{idx.root}",
        ok: "Indexed files in #{idx.root}"
      ]
    )
  end

  @doc """
  Permanently deletes the project from the store.
  """
  def delete_project(idx) do
    Store.delete_project(idx.store)
  end

  defp process_file(idx, file) do
    existing_hash = Store.get_hash(idx.store, file)
    file_hash = sha256(file)

    if is_nil(existing_hash) or existing_hash != file_hash do
      file_contents = File.read!(file)

      with {:ok, summary} <- get_summary(idx, file, file_contents),
           {:ok, embeddings} <- get_embeddings(idx, file, summary, file_contents) do
        Store.put(idx.store, file, file_hash, summary, embeddings)
      else
        {:error, reason} -> IO.puts("Error processing file: #{file} - #{reason}")
      end
    end
  end

  defp get_summary(idx, file, file_contents, attempt \\ 0) do
    idx.ai_module.get_summary(idx.ai, file, file_contents)
    |> case do
      {:ok, summary} ->
        {:ok, summary}

      {:error, %OpenaiEx.Error{message: "Request timed out."}} ->
        if attempt < 3 do
          IO.puts("request to summarize file timed out, retrying (attempt #{attempt + 1}/3)")
          get_summary(idx, file, file_contents, attempt + 1)
        else
          {:error, "request to summarize file timed out after 3 attempts"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_embeddings(idx, file, summary, file_contents, attempt \\ 0) do
    to_embed = """
      # File
      `#{file}`

      ## Summary
      #{summary}

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
          IO.puts("request to index file timed out, retrying (attempt #{attempt + 1}/3)")
          get_embeddings(idx, file, summary, file_contents, attempt + 1)
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
