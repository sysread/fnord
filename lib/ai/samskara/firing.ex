defmodule AI.Samskara.Firing do
  @moduledoc """
  Fires relevant samskaras for a given perception by cosine-similarity search
  over stored record embeddings.
  """

  alias Store.Project.Samskara
  alias Store.Project.Samskara.Record

  @default_k 5
  @min_score 0.25

  @type scored :: {Record.t(), float}

  @doc """
  Returns up to `k` active samskaras most relevant to the given perception,
  each paired with its cosine similarity score, sorted by descending score.
  Records below `@min_score` are filtered out.

  Returns `{:ok, []}` when no samskaras exist or none meet the threshold.
  """
  @spec for_perception(Store.Project.t(), AI.Agent.Perception.Result.t(), pos_integer()) ::
          {:ok, [scored]} | {:error, term}
  def for_perception(project, %AI.Agent.Perception.Result{} = perception, k \\ @default_k) do
    text = AI.Agent.Perception.Result.embed_text(perception)
    for_text(project, text, k)
  end

  @doc """
  Returns up to `k` active samskaras most relevant to a free-text query (used
  by the `fnord samskara fires` CLI to debug the seam).
  """
  @spec for_text(Store.Project.t(), binary, pos_integer()) ::
          {:ok, [scored]} | {:error, term}
  def for_text(_project, "", _k), do: {:ok, []}

  def for_text(project, text, k) when is_binary(text) and is_integer(k) and k > 0 do
    case Samskara.list_active(project) do
      [] ->
        {:ok, []}

      records ->
        with {:ok, query} <- embed(text) do
          scored =
            records
            |> Enum.map(fn r -> {r, AI.Embeddings.cosine_similarity(query, r.embedding)} end)
            |> Enum.filter(fn {_r, score} -> score >= @min_score end)
            |> Enum.sort_by(fn {_r, score} -> score end, :desc)
            |> Enum.take(k)

          log_firings(text, scored)
          {:ok, scored}
        end
    end
  end

  @doc """
  Returns just the records (no scores) — convenience wrapper for callers that
  only need to inject samskaras into agent prompts.
  """
  @spec records_for_perception(Store.Project.t(), AI.Agent.Perception.Result.t(), pos_integer()) ::
          [Record.t()]
  def records_for_perception(project, perception, k \\ @default_k) do
    case for_perception(project, perception, k) do
      {:ok, scored} -> Enum.map(scored, fn {r, _s} -> r end)
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------
  @spec embed(binary) :: {:ok, [float]} | {:error, term}
  def embed(text) when is_binary(text) do
    case AI.Embeddings.get(text) do
      {:ok, vec} when is_list(vec) -> {:ok, vec}
      {:error, _} = err -> err
    end
  end

  defp log_firings(_query, []), do: :ok

  defp log_firings(query, scored) do
    if Util.Env.looks_truthy?("FNORD_DEBUG_SAMSKARA") do
      summary =
        scored
        |> Enum.map(fn {r, s} -> "#{Float.round(s, 3)}\t#{r.reaction}\t#{r.gist}" end)
        |> Enum.join("\n")

      UI.debug("samskara:firing", "query=#{inspect(query)}\n#{summary}")
    end

    :ok
  end
end
