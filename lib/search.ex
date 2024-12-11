defmodule Search do
  defstruct [
    :query,
    :limit,
    :detail,
    :index_module
  ]

  @doc """
  Creates a new `Search` struct with the given options.
  """
  def new(opts, index_module \\ AI) do
    %__MODULE__{
      query: opts[:query],
      limit: opts[:limit],
      detail: opts[:detail],
      index_module: index_module
    }
  end

  def get_results(search) do
    needle = get_query_embeddings(search.query, search.index_module)

    {:ok, queue} =
      Queue.start_link(fn entry ->
        with {:ok, data} <- get_file_data(search, entry) do
          needle
          |> get_score(data)
          |> then(&{entry, &1, data})
        else
          _ -> nil
        end
      end)

    results =
      Store.get_project()
      |> Store.Project.source_files()
      |> Queue.map(queue)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(fn {_, score1, _}, {_, score2, _} -> score1 >= score2 end)
      |> Enum.take(search.limit)

    Queue.shutdown(queue)
    Queue.join(queue)

    results
  end

  defp get_query_embeddings(query, index_module) do
    {:ok, [needle]} = index_module.get_embeddings(index_module.new(), query)
    needle
  end

  defp get_file_data(search, entry) do
    if search.detail do
      Store.Entry.read(entry)
    else
      with {:ok, embeddings} <- Store.Entry.read_embeddings(entry) do
        {:ok, %{"embeddings" => embeddings}}
      end
    end
  end

  defp get_score(needle, %{"embeddings" => embeddings}) do
    cosine_similarity(needle, embeddings)
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
