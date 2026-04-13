defmodule Search.Commits do
  @moduledoc """
  Semantic search over indexed git commits.

  This module uses commit embeddings stored via `Store.Project.CommitIndex`
  to find relevant commits for a natural language query.
  """

  @default_limit 10

  @spec search(Store.Project.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(%Store.Project{} = project, query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, query_vec} <- Indexer.impl().get_embeddings(query) do
      project
      |> Store.Project.CommitIndex.all_embeddings()
      |> Util.async_stream(fn {sha, emb_vec, meta} ->
        score = AI.Util.cosine_similarity(query_vec, emb_vec)
        build_result(sha, meta, score)
      end)
      |> Enum.reduce([], fn
        {:ok, nil}, acc -> acc
        {:ok, result}, acc -> [result | acc]
      end)
      |> Enum.sort_by(fn %{score: sc} -> sc end, :desc)
      |> Enum.take(limit)
      |> then(&{:ok, &1})
    end
  end

  defp build_result(sha, meta, score) do
    %{
      sha: sha,
      subject: Map.get(meta, "subject"),
      author: Map.get(meta, "author"),
      committed_at: Map.get(meta, "committed_at"),
      score: score
    }
  end
end
