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
      q_len = length(needle)

      {scored, dropped} =
        project
        |> Store.Project.CommitIndex.all_embeddings()
        |> Util.async_stream(fn {sha, embeddings, metadata} ->
          # Stale-dimension commits (pre-migration, corrupted, or
          # mid-migration residue) would crash cosine_similarity;
          # return an explicit :dim_mismatch so the caller can count
          # how many we skipped and surface it in the log.
          if is_list(embeddings) and length(embeddings) == q_len do
            score = AI.Util.cosine_similarity(needle, embeddings)
            {:scored, {sha, score, metadata}}
          else
            {:dim_mismatch, sha}
          end
        end)
        |> Enum.reduce({[], 0}, fn
          {:ok, {:scored, item}}, {items, drops} -> {[item | items], drops}
          {:ok, {:dim_mismatch, _sha}}, {items, drops} -> {items, drops + 1}
          _, acc -> acc
        end)

      if dropped > 0 do
        UI.warn(
          "[commit search] skipped #{dropped} indexed commit#{if dropped == 1, do: "", else: "s"}" <>
            " with stale embedding dimensions; run `fnord index` to rebuild."
        )
      end

      results =
        scored
        |> Enum.sort(fn {_, a, _}, {_, b, _} -> a >= b end)
        |> Enum.take(search.limit)

      {:ok, results}
    end
  end
end
