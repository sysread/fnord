defmodule Search do
  defstruct [
    :project,
    :query,
    :limit,
    :detail,
    :store,
    :concurrency,
    :index_module
  ]

  @doc """
  Creates a new `Search` struct with the given options.
  """
  def new(opts, index_module \\ AI) do
    %__MODULE__{
      project: opts[:project],
      query: opts[:query],
      limit: opts[:limit],
      detail: opts[:detail],
      store: Store.new(opts[:project]),
      concurrency: opts[:concurrency],
      index_module: index_module
    }
  end

  def get_results(search) do
    needle = get_query_embeddings(search.query, search.index_module)

    {:ok, queue} =
      Queue.start_link(search.concurrency, fn file ->
        with {:ok, data} <- get_file_data(search, file) do
          get_score(needle, data)
          |> case do
            {:ok, score} -> {file, score, data}
            {:error, :no_embeddings} -> nil
          end
        else
          _ -> nil
        end
      end)

    results =
      search
      |> list_files()
      |> Queue.map(queue)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(fn {_, score1, _}, {_, score2, _} -> score1 >= score2 end)
      |> Enum.take(search.limit)

    Queue.shutdown(queue)
    Queue.join(queue)

    results
  end

  defp get_score(needle, data) do
    data
    |> Map.get("embeddings", [])
    |> Enum.map(fn emb -> cosine_similarity(needle, emb) end)
    |> case do
      [] -> {:error, :no_embeddings}
      scores -> {:ok, Enum.max(scores)}
    end
  end

  defp get_query_embeddings(query, index_module) do
    {:ok, [needle]} = index_module.get_embeddings(index_module.new(), query)
    needle
  end

  defp list_files(search) do
    Store.list_files(search.store)
  end

  defp get_file_data(search, file) do
    if search.detail do
      Store.get(search.store, file)
    else
      with {:ok, embeddings} <- Store.get_embeddings(search.store, file) do
        {:ok, %{"embeddings" => embeddings}}
      else
        {:error, _} -> {:error, :file}
      end
    end
  end

  # Computes the cosine similarity between two vectors
  def cosine_similarity(vec1, vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec1, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec2, 0.0, fn x, acc -> acc + x * x end))

    if magnitude1 == 0.0 or magnitude2 == 0.0 do
      0.0
    else
      dot_product / (magnitude1 * magnitude2)
    end
  end
end
