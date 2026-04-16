defmodule Search.Files do
  defstruct [
    :query,
    :limit,
    :detail
  ]

  def new(opts) do
    %__MODULE__{
      query: opts[:query],
      limit: opts[:limit],
      detail: opts[:detail]
    }
  end

  def get_results(search) do
    with {:ok, project} <- Store.get_project(),
         {:ok, needle} <- Indexer.impl().get_embeddings(search.query) do
      project
      |> Store.Project.stored_files()
      |> Util.async_stream(fn entry ->
        with {:ok, data} <- get_file_data(search, entry),
             {:ok, score} <- get_score(needle, data) do
          {entry, score, data}
        else
          _ -> nil
        end
      end)
      |> Enum.reduce([], fn
        {:ok, nil}, acc -> acc
        {:ok, result}, acc -> [result | acc]
        # A task crash (e.g. malformed embedding on disk) shouldn't take the
        # whole search down - drop the result and keep going.
        _, acc -> acc
      end)
      |> Enum.sort(fn {_, a, _}, {_, b, _} -> a >= b end)
      |> Enum.take(search.limit)
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_file_data(search, entry) do
    if search.detail do
      Store.Project.Entry.read(entry)
    else
      with {:ok, embeddings} <- Store.Project.Entry.read_embeddings(entry) do
        {:ok, %{"embeddings" => embeddings}}
      end
    end
  end

  # Skip entries whose embedding dimension doesn't match the query - most
  # likely they were written by the previous model and haven't been
  # reindexed yet. Returning {:error, :dim_mismatch} lets the caller drop
  # the entry instead of crashing cosine_similarity.
  defp get_score(needle, %{"embeddings" => embeddings})
       when is_list(needle) and is_list(embeddings) do
    if length(needle) == length(embeddings) do
      {:ok, AI.Util.cosine_similarity(needle, embeddings)}
    else
      {:error, :dim_mismatch}
    end
  end

  defp get_score(_needle, _data), do: {:error, :missing_embeddings}
end
