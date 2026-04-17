defmodule AI.Agent.SamskaraConsolidator do
  @moduledoc """
  Collapses near-duplicate samskaras into impression records.

  Algorithm:
    1. Load unconsolidated records (active, not already impressions).
    2. Greedily cluster by cosine similarity of embeddings; records within
       `@similarity_threshold` of a cluster seed join it.
    3. For each cluster of size >= `@min_cluster_size`, call the model to
       synthesize a single "impression" (shared gist + merged lessons).
    4. Persist the impression as a new record with `impression: true`, embed
       its gist, and mark sources as `consolidated_into: <impression_id>`.

  Runs from `fnord index` and from the background indexer at idle.
  """

  @behaviour AI.Agent

  @model AI.Model.fast()

  @similarity_threshold 0.80
  @min_cluster_size 2

  @prompt """
  You are consolidating a cluster of related samskaras (past reactions of the
  user) into a single stable impression. The cluster entries share a theme.

  Respond ONLY with a JSON object:
  - "gist": one-sentence summary capturing the shared theme (third person, <= 200 chars).
  - "lessons": 0-5 deduplicated, clearly-worded actionable takeaways (each <= 140 chars).
  - "tags": 0-5 short lowercase hyphenated tags.
  """

  alias Store.Project.Samskara
  alias Store.Project.Samskara.Record

  @type run_result ::
          {:ok, %{consolidated: non_neg_integer, impressions: non_neg_integer}}
          | {:ok, :noop}
          | {:error, term}

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, project} <- Map.fetch(opts, :project) do
      run(project)
    else
      :error -> {:error, "Missing required argument: project"}
    end
  end

  @spec run(Store.Project.t()) :: run_result
  def run(%Store.Project{} = project) do
    records = Samskara.list_unconsolidated(project)

    if length(records) < @min_cluster_size do
      {:ok, :noop}
    else
      clusters = cluster(records)
      large = Enum.filter(clusters, fn c -> length(c) >= @min_cluster_size end)

      agent = AI.Agent.new(__MODULE__, named?: false)

      {consolidated, impressions} =
        Enum.reduce(large, {0, 0}, fn cluster, {c, i} ->
          case synthesize_and_persist(project, agent, cluster) do
            :ok -> {c + length(cluster), i + 1}
            _ -> {c, i}
          end
        end)

      {:ok, %{consolidated: consolidated, impressions: impressions}}
    end
  end

  # ---------------------------------------------------------------------------
  # Clustering
  # ---------------------------------------------------------------------------
  @spec cluster([Record.t()]) :: [[Record.t()]]
  def cluster(records) when is_list(records) do
    do_cluster(records, [])
  end

  defp do_cluster([], clusters), do: Enum.reverse(clusters)

  defp do_cluster([seed | rest], clusters) do
    {members, remainder} =
      Enum.split_with(rest, fn candidate ->
        AI.Embeddings.cosine_similarity(seed.embedding, candidate.embedding) >= @similarity_threshold
      end)

    do_cluster(remainder, [[seed | members] | clusters])
  end

  # ---------------------------------------------------------------------------
  # Synthesis
  # ---------------------------------------------------------------------------
  defp synthesize_and_persist(project, agent, cluster) do
    with {:ok, %{"gist" => gist} = data} when is_binary(gist) and gist != "" <-
           synthesize(agent, cluster),
         {:ok, embedding} <- AI.Samskara.Firing.embed(gist) do
      impression =
        Record.new(%{
          reaction: :other,
          intensity: 1.0,
          gist: gist,
          lessons: Map.get(data, "lessons", []) |> ensure_list_of_binaries(),
          tags: Map.get(data, "tags", []) |> ensure_list_of_binaries(),
          embedding: embedding,
          impression?: true
        })

      with {:ok, saved} <- Samskara.write(project, impression),
           :ok <- Samskara.mark_consolidated(project, Enum.map(cluster, & &1.id), saved.id) do
        if Util.Env.looks_truthy?("FNORD_DEBUG_SAMSKARA") do
          UI.debug(
            "samskara:consolidate",
            "cluster of #{length(cluster)} -> #{saved.id}: #{saved.gist}"
          )
        end

        :ok
      end
    end
  end

  defp synthesize(agent, cluster) do
    bullets =
      cluster
      |> Enum.map(fn r -> "- [#{r.reaction}] #{r.gist}" end)
      |> Enum.join("\n")

    messages = [
      AI.Util.system_msg(@prompt),
      AI.Util.user_msg("# Cluster entries\n#{bullets}")
    ]

    AI.Agent.get_completion(agent,
      model: @model,
      messages: messages
    )
    |> case do
      {:ok, %{response: response}} ->
        decode_json(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json(str) do
    str
    |> String.trim()
    |> strip_code_fence()
    |> SafeJson.decode()
  end

  defp strip_code_fence(str) do
    str
    |> String.replace(~r/^```(?:json)?\s*/, "")
    |> String.replace(~r/\s*```$/, "")
  end

  defp ensure_list_of_binaries(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp ensure_list_of_binaries(_), do: []
end
