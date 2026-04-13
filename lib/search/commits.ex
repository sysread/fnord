defmodule Search.Commits do
  @moduledoc """
  Semantic search over indexed git commits.

  Given a natural-language query, we embed it and compare against precomputed
  commit embeddings using cosine similarity. Results include the commit SHA,
  similarity score, and selected metadata.
  """

  defstruct [
    :query,
    :limit
  ]

  @type t :: %__MODULE__{
          query: String.t(),
          limit: pos_integer()
        }

  @default_limit 25

  @spec new(Keyword.t() | map()) :: t
  def new(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      query: Map.get(opts, :query) || Map.get(opts, "query"),
      limit: Map.get(opts, :limit) || Map.get(opts, "limit") || @default_limit
    }
  end

  @doc """
  Returns {:ok, results} where results is a list of {sha, score, metadata} tuples,
  ordered by highest similarity and truncated to the provided limit.
  """
  @spec get_results(t) :: {:ok, list({String.t(), number(), map()})} | {:error, any()}
  def get_results(%__MODULE__{} = search) do
    with {:ok, project} <- Store.get_project(),
         {:ok, needle} <- Indexer.impl().get_embeddings(search.query) do
      results =
        project
        |> Store.Project.CommitIndex.all_embeddings()
        |> Util.async_stream(fn {sha, embeddings, metadata} ->
          score = AI.Util.cosine_similarity(needle, embeddings)
          {sha, score, metadata}
        end)
        |> Enum.reduce([], fn
          {:ok, item}, acc -> [item | acc]
          _, acc -> acc
        end)
        |> Enum.sort(fn {_, a, _}, {_, b, _} -> a >= b end)
        |> Enum.take(search.limit)

      {:ok, results}
    end
  end
end
