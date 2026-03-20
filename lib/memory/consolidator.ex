defmodule Memory.Consolidator do
  @moduledoc """
  Orchestrates long-term memory consolidation. Processes global and project
  scopes as independent batches (in parallel). Within each scope, a
  coordinator GenServer owns the similarity matrix and the set of remaining
  memories, handing out work items to concurrent workers. Workers ask the
  coordinator for a focus memory and its live candidates, call the LLM agent,
  apply the results, and report back which memories were consumed.

  This module is invoked by `Cmd.Memory defrag` and runs synchronously in
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
  scopes run in parallel since consolidation is walled - no cross-scope merges.

  Returns a combined report summarizing what happened across both scopes.
  """
  @spec run() :: {:ok, report} | {:error, term}
  def run() do
    HttpPool.set(:ai_memory)

    with {:ok, global_memories} <- load_memories(:global),
         {:ok, project_memories} <- load_memories(:project) do
      total = length(global_memories) + length(project_memories)

      # Process global and project scopes in parallel. Each scope gets its own
      # coordinator GenServer and worker pool.
      global_task =
        Services.Globals.Spawn.async(fn ->
          HttpPool.set(:ai_memory)
          safe_consolidate_scope(:global, global_memories)
        end)

      project_task =
        Services.Globals.Spawn.async(fn ->
          HttpPool.set(:ai_memory)
          safe_consolidate_scope(:project, project_memories)
        end)

      global_report = Task.await(global_task, :infinity)
      project_report = Task.await(project_task, :infinity)

      {:ok, merge_reports(global_report, project_report, total)}
    end
  end

  # --------------------------------------------------------------------------
  # Per-scope orchestration
  # --------------------------------------------------------------------------

  # Guard against a scope-level crash taking down the whole consolidation run.
  defp safe_consolidate_scope(scope_name, memories) do
    consolidate_scope(memories)
  rescue
    e ->
      UI.error("consolidator", "#{scope_name} scope crashed: #{Exception.message(e)}")
      %{merged: 0, deleted: 0, kept: 0, errors: length(memories)}
  catch
    :exit, reason ->
      UI.error("consolidator", "#{scope_name} scope exited: #{inspect(reason)}")
      %{merged: 0, deleted: 0, kept: 0, errors: length(memories)}
  end

  # Start a pool for this scope, spawn workers, collect results.
  defp consolidate_scope([]) do
    %{merged: 0, deleted: 0, kept: 0, errors: 0}
  end

  defp consolidate_scope(memories) do
    {:ok, coordinator} = Services.MemoryConsolidation.start_link(memories)

    try do
      # Spawn workers that pull from the coordinator until it's drained.
      # Each worker loops: checkout → process → complete → repeat.
      worker_count = System.schedulers_online()

      1..worker_count
      |> Util.async_stream(fn _ ->
        worker_loop(coordinator)
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
  defp worker_loop(coordinator) do
    HttpPool.set(:ai_memory)

    case Services.MemoryConsolidation.checkout(coordinator) do
      :done ->
        :ok

      {:ok, focus, candidates} ->
        result = process_one(coordinator, focus, candidates)
        Services.MemoryConsolidation.complete(coordinator, focus, result)
        worker_loop(coordinator)

      {:skip, _focus} ->
        # No live candidates - coordinator already counted it as kept.
        worker_loop(coordinator)
    end
  end

  # Wrap individual focus processing so a single failure doesn't kill the
  # entire worker. Catches both exceptions and unexpected exits from the
  # LLM pipeline.
  defp process_one(_coordinator, focus, candidates) do
    process_focus(focus, candidates)
  rescue
    e ->
      UI.error("consolidator", "Worker crashed on #{focus.title}: #{Exception.message(e)}")
      {:error, []}
  catch
    :exit, reason ->
      UI.error("consolidator", "Worker exited on #{focus.title}: #{inspect(reason)}")
      {:error, []}
  end

  # --------------------------------------------------------------------------
  # Focus processing (runs in worker)
  # --------------------------------------------------------------------------

  # Process a single focus memory: first try a bounded ownership pre-step for
  # suspicious global memories, then fall back to the consolidator agent.
  # Returns the same result tuples consumed by the coordinator.
  defp process_focus(focus, candidates) do
    case maybe_move_global_focus_to_project(focus) do
      {:delete, eaten} ->
        {:delete, eaten}

      :continue ->
        case run_agent(focus, candidates) do
          {:ok, decoded} ->
            apply_actions(focus, decoded)

          {:error, reason} ->
            UI.warn("Consolidation failed for #{focus.title}", inspect(reason))
            {:error, []}
        end
    end
  end

  # For suspicious global memories, score ownership against projects before the
  # normal global consolidator runs. A confident move consumes the global focus
  # immediately; otherwise the usual agent path continues.
  defp maybe_move_global_focus_to_project(%Memory{scope: :global} = focus) do
    with true <- Memory.ScopePolicy.allow_automatic_move?(focus, :project),
         true <- Memory.ProjectOwnership.suspicious_global_memory?(focus),
         {:ok, verdict} <- Memory.ProjectOwnership.classify(focus),
         {:move, project, score, margin} <- ownership_move(verdict),
         {:ok, _moved} <- move_focus_to_project(focus, project) do
      UI.debug(
        "consolidator",
        "Moved suspicious global memory #{focus.title} to project #{project} (score=#{Float.round(score, 4)}, margin=#{Float.round(margin, 4)})"
      )

      {:delete, []}
    else
      _ -> :continue
    end
  end

  defp maybe_move_global_focus_to_project(_focus), do: :continue

  defp ownership_move(%{project: project, score: score, margin: margin, confident: true})
       when is_binary(project) and is_number(score) and is_number(margin) do
    {:move, project, score, margin}
  end

  defp ownership_move(_), do: :continue

  # Apply the agent's decisions to disk. Returns {:ok, eaten_slugs},
  # {:delete, eaten_slugs}, or {:error, eaten_slugs}.
  defp apply_actions(focus, decoded) do
    actions = Map.get(decoded, "actions", [])
    keep = Map.get(decoded, "keep", true)

    case apply_actions_list(focus, actions) do
      {:ok, eaten} ->
        maybe_delete_focus(focus, keep, eaten, decoded)

      {:delete, eaten} ->
        {:delete, eaten}

      {:error, eaten} ->
        {:error, eaten}
    end
  end

  defp apply_actions_list(focus, actions) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, eaten} ->
      case apply_action(focus, action) do
        {:ok, more_eaten} ->
          {:cont, {:ok, eaten ++ more_eaten}}

        {:delete, more_eaten} ->
          {:halt, {:delete, eaten ++ more_eaten}}

        {:error, more_eaten} ->
          {:halt, {:error, eaten ++ more_eaten}}
      end
    end)
  end

  defp maybe_delete_focus(focus, keep, eaten, decoded) do
    if keep or me_memory?(focus) do
      if not keep and me_memory?(focus) do
        UI.debug("consolidator", "Refused to delete Me identity memory")
      end

      {:ok, eaten}
    else
      keep_reason = Map.get(decoded, "reason", "no reason given")

      case Memory.forget(focus) do
        :ok ->
          UI.debug("consolidator", "Deleted focus: #{focus.title} - #{keep_reason}")
          {:delete, eaten}

        {:error, reason} ->
          UI.warn("Failed to delete focus #{focus.title}", inspect(reason))
          {:error, eaten}
      end
    end
  end

  # Merge: rewrite the focus memory's content, then delete the candidate.
  # Returns consumed slug keys for candidates eaten by the merge.
  defp apply_action(
         focus,
         %{"action" => "merge", "target" => target, "content" => content} = action
       ) do
    scope = parse_scope(target["scope"])

    # Enforce scope walling - reject actions targeting a different scope than
    # the focus memory being consolidated.
    if scope != focus.scope do
      UI.warn(
        "consolidator",
        "Rejected cross-scope merge targeting #{scope} from #{focus.scope} scope"
      )

      {:ok, []}
    else
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
              case Memory.forget(candidate) do
                :ok ->
                  UI.debug("consolidator", "Merged #{title} into #{focus.title} - #{reason}")
                  {:ok, [{scope, slug}]}

                {:error, reason} ->
                  UI.warn("Failed to delete merged candidate #{title}", inspect(reason))
                  {:error, []}
              end

            {:error, _} ->
              # Candidate already gone - another worker ate it.
              {:ok, [{scope, slug}]}
          end

        {:error, reason} ->
          UI.warn("Failed to save merged memory #{focus.title}", inspect(reason))
          {:error, []}
      end
    end
  end

  # Move: re-home the global focus memory into project scope. This uses the same
  # explicit save+forget flow as project ownership reassignment, rather than
  # pretending the move is a merge or candidate delete.
  defp apply_action(focus, %{"action" => "move", "target" => target} = action) do
    target_scope = parse_scope(target["scope"])
    project = target["title"]
    reason = Map.get(action, "reason", "no reason given")

    if valid_move_target?(focus, target_scope, project) do
      case move_focus_to_project(focus, project) do
        {:ok, _moved} ->
          UI.debug("consolidator", "Moved #{focus.title} to project #{project} - #{reason}")
          {:delete, []}

        {:error, reason} ->
          UI.warn("Failed to move #{focus.title} to project #{project}", inspect(reason))
          {:error, []}
      end
    else
      UI.warn(
        "consolidator",
        "Rejected invalid move targeting #{inspect(target_scope)}:#{inspect(project)} from #{focus.scope} scope"
      )

      {:ok, []}
    end
  end

  # Delete: remove a candidate outright. The Me identity memory is never
  # deletable - the coordinator already excludes it from candidates, but
  # this is a safety net in case the agent hallucinates a target.
  defp apply_action(_focus, %{
         "action" => "delete",
         "target" => %{"scope" => "global", "title" => "Me"}
       }) do
    UI.debug("consolidator", "Refused to delete Me identity memory")
    {:ok, []}
  end

  defp apply_action(focus, %{"action" => "delete", "target" => target} = action) do
    scope = parse_scope(target["scope"])

    # Enforce scope walling - reject actions targeting a different scope than
    # the focus memory being consolidated.
    if scope != focus.scope do
      UI.warn(
        "consolidator",
        "Rejected cross-scope delete targeting #{scope} from #{focus.scope} scope"
      )

      {:ok, []}
    else
      title = target["title"]
      slug = Memory.title_to_slug(title)
      reason = Map.get(action, "reason", "no reason given")

      case Memory.read(scope, title) do
        {:ok, memory} ->
          case Memory.forget(memory) do
            :ok ->
              UI.debug("consolidator", "Deleted: #{title} - #{reason}")
              {:ok, [{scope, slug}]}

            {:error, reason} ->
              UI.warn("Failed to delete #{title}", inspect(reason))
              {:error, []}
          end

        {:error, _} ->
          # Already gone.
          {:ok, []}
      end
    end
  end

  defp apply_action(_, _), do: {:ok, []}

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
      |> SafeJson.encode!()

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
    case SafeJson.decode(response) do
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
         "target" => %{"scope" => scope, "title" => _},
         "content" => _
       }) do
    valid_scope_string?(scope)
  end

  defp valid_action?(%{"action" => "move", "target" => %{"scope" => "project", "title" => title}}) do
    is_binary(title)
  end

  defp valid_action?(%{"action" => "delete", "target" => %{"scope" => scope, "title" => _}}) do
    valid_scope_string?(scope)
  end

  defp valid_action?(_), do: false

  defp valid_move_target?(%Memory{} = focus, :project, project) when is_binary(project) do
    Memory.ScopePolicy.allow_automatic_move?(focus, :project)
  end

  defp valid_move_target?(_, _, _), do: false

  defp move_focus_to_project(focus, project),
    do: Memory.ProjectOwnership.move_to_project(focus, project)

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

  defp valid_scope_string?("global"), do: true
  defp valid_scope_string?("project"), do: true
  defp valid_scope_string?(_), do: false

  defp parse_scope("global"), do: :global
  defp parse_scope("project"), do: :project

  defp me_memory?(%Memory{scope: :global, title: "Me"}), do: true
  defp me_memory?(_), do: false

  @doc """
  Return the tier label for the given score:

  - "high" for scores > 0.5
  - "moderate" for scores >= 0.3
  - "low" otherwise
  """
  def tier_label(score) when score > 0.5, do: "high"
  def tier_label(score) when score >= 0.3, do: "moderate"
  def tier_label(_), do: "low"
end
