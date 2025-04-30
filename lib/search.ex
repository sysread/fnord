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
    with {:ok, needle} <- get_query_embeddings(search.query) do
      Store.get_project()
      |> Store.Project.stored_files()
      |> Util.async_stream(fn entry ->
        with {:ok, data} <- get_file_data(search, entry) do
          needle
          |> get_score(data)
          |> then(&{entry, &1, data})
        else
          _ -> nil
        end
      end)
      |> Enum.reduce([], fn
        {:ok, nil}, acc -> acc
        {:ok, result}, acc -> [result | acc]
      end)
      |> Enum.sort(fn {_, a, _}, {_, b, _} -> a >= b end)
      |> Enum.take(search.limit)
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_query_embeddings(query) do
    idx = Indexer.impl()
    idx.get_embeddings(idx.new(), query)
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
