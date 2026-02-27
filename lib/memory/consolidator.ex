defmodule Memory.Consolidator do
  @moduledoc """
  Orchestrates long-term memory consolidation. Processes global and project
  scopes as independent batches (in parallel). Within each scope, a
  coordinator GenServer owns the similarity matrix and the set of remaining
  memories, handing out work items to concurrent workers. Workers ask the
  coordinator for a focus memory and its live candidates, call the LLM agent,
  apply the results, and report back which memories were consumed.

  This module is invoked by `Cmd.Index --long-con` and runs synchronously in
  the foreground.
  """

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
  processed by its own coordinator GenServer with concurrent workers. The two
  scopes run in parallel since consolidation is walled — no cross-scope merges.

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

      # Process global and project scopes in parallel. Each scope gets its own
      # coordinator GenServer and worker pool.
      global_task =
        Services.Globals.Spawn.async(fn ->
          HttpPool.set(:ai_memory)
          consolidate_scope(global_memories, on_progress)
        end)

      project_task =
        Services.Globals.Spawn.async(fn ->
          HttpPool.set(:ai_memory)
          consolidate_scope(project_memories, on_progress)
        end)

      global_report = Task.await(global_task, :infinity)
      project_report = Task.await(project_task, :infinity)

      {:ok, merge_reports(global_report, project_report, total)}
    end
  end

  # --------------------------------------------------------------------------
  # Per-scope orchestration
  # --------------------------------------------------------------------------

  # Start a coordinator for this scope, spawn workers, collect results.
  defp consolidate_scope([], _on_progress) do
    %{merged: 0, deleted: 0, kept: 0, errors: 0}
  end

  defp consolidate_scope(memories, on_progress) do
    {:ok, coordinator} = Services.MemoryConsolidation.start_link(memories)

    try do
      # Spawn workers that pull from the coordinator until it's drained.
      # Each worker loops: checkout → process → complete → repeat.
      worker_count = System.schedulers_online()

      1..worker_count
      |> Util.async_stream(fn _ ->
        worker_loop(coordinator, on_progress)
      end)
      |> Enum.to_list()

      Services.MemoryConsolidation.report(coordinator)
    after
      GenServer.stop(coordinator)
    end
  end

  # --------------------------------------------------------------------------
  # Worker loop
  # --------------------------------------------------------------------------

  # Each worker repeatedly checks out a focus memory from the coordinator,
  # processes it, and reports back. Stops when the coordinator has no more
  # work.
  defp worker_loop(coordinator, on_progress) do
    HttpPool.set(:ai_memory)

    case Services.MemoryConsolidation.checkout(coordinator) do
      :done ->
        :ok

      {:ok, focus, candidates} ->
        result = process_focus(focus, candidates)
        Services.MemoryConsolidation.complete(coordinator, focus, result)
        on_progress.()
        worker_loop(coordinator, on_progress)

      {:skip, _focus} ->
        # No live candidates — coordinator already counted it as kept.
        on_progress.()
        worker_loop(coordinator, on_progress)
    end
  end

  # --------------------------------------------------------------------------
  # Focus processing (runs in worker)
  # --------------------------------------------------------------------------

  # Process a single focus memory: ask the agent, apply actions. Returns a
  # result tuple the coordinator can use to update its state.
  defp process_focus(focus, candidates) do
    case run_agent(focus, candidates) do
      {:ok, decoded} ->
        apply_actions(focus, decoded)

      {:error, reason} ->
        UI.warn("Consolidation failed for #{focus.title}", inspect(reason))
        {:error, []}
    end
  end

  # Apply the agent's decisions to disk. Returns {:ok | :delete, eaten_slugs}
  # or {:error, eaten_slugs} so the coordinator knows what was consumed.
  defp apply_actions(focus, decoded) do
    actions = Map.get(decoded, "actions", [])
    keep = Map.get(decoded, "keep", true)

    eaten =
      actions
      |> Enum.flat_map(&apply_action(focus, &1))

    if keep do
      {:ok, eaten}
    else
      keep_reason = Map.get(decoded, "reason", "no reason given")

      case Memory.forget(focus) do
        :ok ->
          UI.debug("consolidator", "Deleted focus: #{focus.title} — #{keep_reason}")
          {:delete, eaten}

        {:error, reason} ->
          UI.warn("Failed to delete focus #{focus.title}", inspect(reason))
          {:error, eaten}
      end
    end
  end

  # Merge: rewrite the focus memory's content, then delete the candidate.
  # Returns a list of eaten slug keys (0 or 1 element).
  defp apply_action(
         focus,
         %{"action" => "merge", "target" => target, "content" => content} = action
       ) do
    scope = parse_scope(target["scope"])
    title = target["title"]
    slug = Memory.title_to_slug(title)
    reason = Map.get(action, "reason", "no reason given")

    # Save the merged content onto the focus memory. Clear embeddings so they
    # regenerate on next search.
    merged_focus = %{focus | content: content, embeddings: nil}

    case Memory.save(merged_focus) do
      {:ok, _} ->
        case Memory.read(scope, title) do
          {:ok, candidate} ->
            Memory.forget(candidate)
            UI.debug("consolidator", "Merged #{title} into #{focus.title} — #{reason}")

          {:error, _} ->
            # Candidate already gone — another worker ate it.
            :ok
        end

        [{scope, slug}]

      {:error, reason} ->
        UI.warn("Failed to save merged memory #{focus.title}", inspect(reason))
        []
    end
  end

  # Delete: remove a candidate outright.
  defp apply_action(_focus, %{"action" => "delete", "target" => target} = action) do
    scope = parse_scope(target["scope"])
    title = target["title"]
    slug = Memory.title_to_slug(title)
    reason = Map.get(action, "reason", "no reason given")

    case Memory.read(scope, title) do
      {:ok, memory} ->
        case Memory.forget(memory) do
          :ok ->
            UI.debug("consolidator", "Deleted: #{title} — #{reason}")
            [{scope, slug}]

          {:error, reason} ->
            UI.warn("Failed to delete #{title}", inspect(reason))
            []
        end

      {:error, _} ->
        # Already gone.
        []
    end
  end

  defp apply_action(_, _), do: []

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
  # Helpers
  # --------------------------------------------------------------------------

  defp merge_reports(a, b, total) do
    %{
      merged: a.merged + b.merged,
      deleted: a.deleted + b.deleted,
      kept: a.kept + b.kept,
      errors: a.errors + b.errors,
      total: total
    }
  end

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

  defp parse_scope("global"), do: :global
  defp parse_scope("project"), do: :project

  @doc false
  def tier_label(score) when score > 0.5, do: "high"
  def tier_label(score) when score >= 0.3, do: "moderate"
  def tier_label(_), do: "low"
end
