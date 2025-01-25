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
    workers = Application.get_env(:fnord, :workers)

    Store.get_project()
    |> Store.Project.stored_files()
    |> Task.async_stream(
      fn entry ->
        with {:ok, data} <- get_file_data(search, entry) do
          needle
          |> get_score(data)
          |> then(&{entry, &1, data})
        else
          _ -> nil
        end
      end,
      max_concurrency: workers,
      timeout: :infinity
    )
    |> Enum.reduce([], fn {:ok, result}, acc ->
      if is_nil(result) do
        acc
      else
        [result | acc]
      end
    end)
    |> Enum.sort(fn {_, score1, _}, {_, score2, _} -> score1 >= score2 end)
    |> Enum.take(search.limit)
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
