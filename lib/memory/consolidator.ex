defmodule Memory.Consolidator do
  @moduledoc """
  Orchestrates long-term memory consolidation. Processes global and project
  scopes as independent batches (in parallel), using cosine similarity to
  find near-duplicates within each scope, then delegates merge/delete
  decisions to the Consolidator agent.

  This module is invoked by `Cmd.Index --long-con` and runs synchronously in
  the foreground. It is not a GenServer — just a pipeline of pure-ish functions
  that read memories, call the LLM, and apply the results.
  """

  # Cosine similarity floor. Candidates below this score are not sent to the
  # agent at all — they're too dissimilar to be worth evaluating.
  @similarity_floor 0.25

  # Maximum candidates to send per focus memory.
  @max_candidates 10

  @type report :: %{
          merged: non_neg_integer,
          deleted: non_neg_integer,
          kept: non_neg_integer,
          errors: non_neg_integer,
          total: non_neg_integer
        }

  # --------------------------------------------------------------------------
  # Entry point
  # --------------------------------------------------------------------------

  @doc """
  Run memory consolidation across global and project scopes. Each scope is
  processed as an independent batch — global and project run in parallel
  since consolidation is walled to scope (no cross-scope merges).

  Options:
  - `:on_progress` — zero-arity function called after each memory is
    evaluated, regardless of outcome. Useful for driving a progress bar.

  Returns a combined report summarizing what happened across both scopes.
  """
  @spec run(keyword()) :: {:ok, report} | {:error, term}
  def run(opts \\ []) do
    HttpPool.set(:ai_memory)
    on_progress = Keyword.get(opts, :on_progress, fn -> :ok end)

    with {:ok, global_memories} <- load_memories(:global),
         {:ok, project_memories} <- load_memories(:project) do
      total = length(global_memories) + length(project_memories)

      # Process global and project scopes in parallel. Each batch is
      # self-contained — no cross-scope merges, so no shared state.
      global_task =
        Services.Globals.Spawn.async(fn ->
          HttpPool.set(:ai_memory)
          consolidate_batch(global_memories, on_progress)
        end)

      project_task =
        Services.Globals.Spawn.async(fn ->
          HttpPool.set(:ai_memory)
          consolidate_batch(project_memories, on_progress)
        end)

      global_report = Task.await(global_task, :infinity)
      project_report = Task.await(project_task, :infinity)

      {:ok, merge_reports(global_report, project_report, total)}
    end
  end

  # --------------------------------------------------------------------------
  # Batch processing
  # --------------------------------------------------------------------------

  # Process a single scope's memories serially. Returns a partial report.
  defp consolidate_batch(memories, on_progress) do
    report = %{merged: 0, deleted: 0, kept: 0, errors: 0}

    {_processed, final_report} =
      Enum.reduce(memories, {MapSet.new(), report}, fn memory, {processed, report} ->
        result =
          if MapSet.member?(processed, slug_key(memory)) do
            # Already consumed by a merge/delete in an earlier iteration.
            {processed, report}
          else
            consolidate_one(memory, memories, processed, report)
          end

        on_progress.()
        result
      end)

    final_report
  end

  defp merge_reports(a, b, total) do
    %{
      merged: a.merged + b.merged,
      deleted: a.deleted + b.deleted,
      kept: a.kept + b.kept,
      errors: a.errors + b.errors,
      total: total
    }
  end

  # --------------------------------------------------------------------------
  # Per-memory consolidation
  # --------------------------------------------------------------------------

  # Process a single focus memory: find same-scope candidates, ask the agent,
  # apply actions, and update the running report and processed set.
  defp consolidate_one(focus, scope_memories, processed, report) do
    case find_candidates(focus, scope_memories, processed) do
      # No candidates above the similarity floor — nothing to consolidate.
      [] ->
        UI.debug("consolidator", "No candidates for: #{focus.title}")
        {MapSet.put(processed, slug_key(focus)), bump(report, :kept)}

      candidates ->
        case run_agent(focus, candidates) do
          {:ok, decoded} ->
            apply_and_track(focus, decoded, processed, report)

          {:error, reason} ->
            UI.warn("Consolidation failed for #{focus.title}", inspect(reason))
            {MapSet.put(processed, slug_key(focus)), bump(report, :errors)}
        end
    end
  end

  # --------------------------------------------------------------------------
  # Candidate discovery
  # --------------------------------------------------------------------------

  @doc """
  Find memories similar to `focus` using cosine similarity. Only considers
  memories within the same scope — consolidation does not cross scope
  boundaries. Excludes the focus itself and any memories already consumed
  by earlier consolidation passes.

  Returns up to #{@max_candidates} candidates above the similarity floor,
  sorted by score descending.
  """
  @spec find_candidates(Memory.t(), list(Memory.t()), MapSet.t()) ::
          list(%{memory: Memory.t(), score: float, tier: String.t()})
  def find_candidates(focus, scope_memories, processed) do
    case focus.embeddings do
      nil ->
        []

      needle ->
        scope_memories
        |> Enum.reject(fn m ->
          slug_key(m) == slug_key(focus) or
            MapSet.member?(processed, slug_key(m)) or
            is_nil(m.embeddings)
        end)
        |> Enum.map(fn m ->
          score = AI.Util.cosine_similarity(needle, m.embeddings)
          %{memory: m, score: score, tier: tier_label(score)}
        end)
        |> Enum.filter(fn %{score: score} -> score >= @similarity_floor end)
        |> Enum.sort_by(fn %{score: score} -> score end, :desc)
        |> Enum.take(@max_candidates)
    end
  end

  # --------------------------------------------------------------------------
  # Agent invocation
  # --------------------------------------------------------------------------

  # Build the JSON payload and send it to the Consolidator agent. Returns the
  # parsed JSON response or an error.
  defp run_agent(focus, candidates) do
    payload =
      %{
        focus: %{
          scope: to_string(focus.scope),
          title: focus.title,
          content: focus.content,
          topics: focus.topics
        },
        candidates:
          Enum.map(candidates, fn %{memory: m, score: score, tier: tier} ->
            %{
              scope: to_string(m.scope),
              title: m.title,
              content: m.content,
              topics: m.topics,
              score: Float.round(score, 4),
              tier: tier
            }
          end)
      }
      |> Jason.encode!()

    with {:ok, response} <- invoke_agent(payload),
         {:ok, decoded} <- parse_response(response),
         :ok <- validate_response(decoded) do
      {:ok, decoded}
    end
  end

  defp invoke_agent(json_payload) do
    AI.Agent.Memory.Consolidator
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{payload: json_payload})
  end

  defp parse_response(response) do
    case Jason.decode(response) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp validate_response(%{"actions" => actions, "keep" => keep})
       when is_list(actions) and is_boolean(keep) do
    if Enum.all?(actions, &valid_action?/1) do
      :ok
    else
      {:error, "invalid action object"}
    end
  end

  defp validate_response(_), do: {:error, "missing required keys (actions, keep)"}

  defp valid_action?(%{
         "action" => "merge",
         "target" => %{"scope" => _, "title" => _},
         "content" => _
       }),
       do: true

  defp valid_action?(%{"action" => "delete", "target" => %{"scope" => _, "title" => _}}),
    do: true

  defp valid_action?(_), do: false

  # --------------------------------------------------------------------------
  # Action application
  # --------------------------------------------------------------------------

  # Apply the agent's decisions and return updated processed set + report.
  defp apply_and_track(focus, decoded, processed, report) do
    actions = Map.get(decoded, "actions", [])
    keep = Map.get(decoded, "keep", true)

    # Apply each action, tracking which memories were consumed and counting
    # merges/deletes for the report.
    {processed, report} =
      Enum.reduce(actions, {processed, report}, fn action, {proc, rep} ->
        apply_action(focus, action, proc, rep)
      end)

    # If the agent says the focus itself is redundant, delete it.
    {processed, report} =
      if keep do
        {MapSet.put(processed, slug_key(focus)), bump(report, :kept)}
      else
        case Memory.forget(focus) do
          :ok ->
            UI.debug("consolidator", "Deleted focus: #{focus.title}")
            {MapSet.put(processed, slug_key(focus)), bump(report, :deleted)}

          {:error, reason} ->
            UI.warn("Failed to delete focus #{focus.title}", inspect(reason))
            {MapSet.put(processed, slug_key(focus)), bump(report, :errors)}
        end
      end

    {processed, report}
  end

  # Merge: rewrite the focus memory's content, then delete the candidate.
  defp apply_action(
         focus,
         %{"action" => "merge", "target" => target, "content" => content},
         processed,
         report
       ) do
    scope = parse_scope(target["scope"])
    title = target["title"]

    # Save the merged content onto the focus memory. Clear embeddings so they
    # regenerate on next search.
    merged_focus = %{focus | content: content, embeddings: nil}

    case Memory.save(merged_focus) do
      {:ok, _} ->
        # Delete the candidate that was merged in.
        case Memory.read(scope, title) do
          {:ok, candidate} ->
            Memory.forget(candidate)
            UI.debug("consolidator", "Merged #{title} into #{focus.title}")
            {MapSet.put(processed, {scope, Memory.title_to_slug(title)}), bump(report, :merged)}

          {:error, _} ->
            # Candidate already gone — count as merged anyway.
            {MapSet.put(processed, {scope, Memory.title_to_slug(title)}), bump(report, :merged)}
        end

      {:error, reason} ->
        UI.warn("Failed to save merged memory #{focus.title}", inspect(reason))
        {processed, bump(report, :errors)}
    end
  end

  # Delete: remove a candidate outright.
  defp apply_action(_focus, %{"action" => "delete", "target" => target}, processed, report) do
    scope = parse_scope(target["scope"])
    title = target["title"]

    case Memory.read(scope, title) do
      {:ok, memory} ->
        case Memory.forget(memory) do
          :ok ->
            UI.debug("consolidator", "Deleted: #{title}")
            {MapSet.put(processed, {scope, Memory.title_to_slug(title)}), bump(report, :deleted)}

          {:error, reason} ->
            UI.warn("Failed to delete #{title}", inspect(reason))
            {processed, bump(report, :errors)}
        end

      {:error, _} ->
        # Already gone.
        {processed, report}
    end
  end

  defp apply_action(_, _, processed, report), do: {processed, report}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Load memories for a single scope, generating embeddings on demand for any
  # that lack them.
  defp load_memories(scope) do
    with {:ok, titles} <- Memory.list(scope) do
      memories =
        titles
        |> Enum.reduce([], fn title, acc ->
          case Memory.read(scope, title) do
            {:ok, %{embeddings: nil} = mem} ->
              case Memory.generate_embeddings(mem) do
                {:ok, mem_with_emb} ->
                  Memory.save(mem_with_emb, skip_embeddings: true)
                  [mem_with_emb | acc]

                {:error, _} ->
                  acc
              end

            {:ok, mem} ->
              [mem | acc]

            {:error, _} ->
              acc
          end
        end)
        |> Enum.reverse()

      {:ok, memories}
    end
  end

  defp slug_key(%Memory{scope: scope, slug: slug}) when is_binary(slug), do: {scope, slug}
  defp slug_key(%Memory{scope: scope, title: title}), do: {scope, Memory.title_to_slug(title)}

  defp parse_scope("global"), do: :global
  defp parse_scope("project"), do: :project

  defp tier_label(score) when score > 0.5, do: "high"
  defp tier_label(score) when score >= 0.3, do: "moderate"
  defp tier_label(_), do: "low"

  defp bump(report, key), do: Map.update!(report, key, &(&1 + 1))
end
