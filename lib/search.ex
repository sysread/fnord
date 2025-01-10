defmodule Search do
  defstruct [
    :query,
    :limit,
    :detail
  ]

  @doc """
  Creates a new `Search` struct with the given options.
  """
  def new(opts) do
    %__MODULE__{
      query: opts[:query],
      limit: opts[:limit],
      detail: opts[:detail]
    }
  end

  def get_results(search) do
    needle = get_query_embeddings(search.query)

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

  defp get_query_embeddings(query) do
    idx = Indexer.impl()
    {:ok, needle} = idx.get_embeddings(idx.new(), query)
    needle
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

  defp get_score(needle, %{"embeddings" => embeddings}) do
    AI.Util.cosine_similarity(needle, embeddings)
  end
end
