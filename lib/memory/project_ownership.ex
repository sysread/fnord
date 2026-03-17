defmodule Memory.ProjectOwnership do
  @moduledoc """
  Scores suspicious global memories against all known projects to determine
  whether a memory likely belongs to a specific project.

  Ownership scoring is intentionally bounded and stable. The scorer reads
  compact per-project notes directly from project storage, generates embeddings
  for those notes, and compares them to the candidate memory's embeddings. A
  project match is accepted only when it clears both a minimum score and a
  margin over the runner-up project.
  """

  @min_project_match_score 0.45
  @min_project_match_margin 0.08
  @notes_preview_bytes 4000

  @type match :: %{
          project: String.t(),
          score: float()
        }

  @type classification :: %{
          project: String.t(),
          score: float(),
          margin: float(),
          confident: true
        }

  @type verdict :: {:ok, classification()} | :inconclusive | {:error, term()}

  @doc """
  Scores a global memory against all known projects and returns structured
  ownership details only when the best match is both strong enough and clearly
  ahead of the runner-up.

  Returns `:inconclusive` when no project is a confident match.
  """
  @spec classify(Memory.t()) :: verdict()
  def classify(%Memory{scope: :global, embeddings: embeddings} = memory)
      when is_list(embeddings) do
    with {:ok, matches} <- score_projects(memory) do
      choose_winner(matches)
    end
  end

  def classify(%Memory{scope: :global}), do: {:error, :missing_embeddings}

  def classify(_memory), do: :inconclusive

  @doc """
  Returns true only for global memories that are eligible for automatic moves
  under `Memory.ScopePolicy` and that also contain project-ownership signals
  strong enough to justify ownership classification.

  The heuristic is intentionally bounded and deterministic.
  """
  @spec suspicious_global_memory?(Memory.t()) :: boolean()
  def suspicious_global_memory?(%Memory{scope: :global} = memory) do
    Memory.ScopePolicy.automatic_move_candidate?(memory) and
      (
        text = memory_text(memory)

        Enum.any?([
          mentions_code_identifier?(text),
          mentions_file_path?(text),
          mentions_cli_or_workflow_term?(text),
          mentions_projectish_tokens?(text)
        ])
      )
  end

  def suspicious_global_memory?(_memory), do: false

  @doc """
  Moves a global memory into the named project by writing a project-scoped copy
  directly into that project's storage and removing the original global memory
  only after the project write succeeds.
  """
  @spec move_to_project(Memory.t(), String.t()) :: {:ok, Memory.t()} | {:error, term()}
  def move_to_project(%Memory{scope: :global} = memory, project_name)
      when is_binary(project_name) do
    with :ok <- Memory.ScopePolicy.validate_scope(memory, :project),
         {:ok, project_memory} <- save_into_project(memory, project_name),
         :ok <- Memory.forget(memory) do
      {:ok, project_memory}
    else
      {:error, :invalid_scope} -> {:error, :invalid_target_scope}
      {:error, :project_scope_not_allowed} -> {:error, :invalid_target_scope}
      {:error, reason} -> {:error, reason}
    end
  end

  def move_to_project(_memory, _project_name), do: {:error, :invalid_memory}

  defp score_projects(memory) do
    matches =
      Settings.new()
      |> Settings.list_projects()
      |> Enum.reduce([], fn project_name, acc ->
        case score_project(memory, project_name) do
          {:ok, match} -> [match | acc]
          :skip -> acc
        end
      end)
      |> Enum.sort_by(& &1.score, :desc)

    {:ok, matches}
  end

  defp score_project(%Memory{embeddings: embeddings}, project_name) do
    with {:ok, notes} <- project_notes(project_name),
         {:ok, notes_embeddings} <- embeddings_for_notes(project_name, notes),
         true <- compatible_embeddings?(embeddings, notes_embeddings) do
      score = AI.Util.cosine_similarity(embeddings, notes_embeddings)
      {:ok, %{project: project_name, score: score}}
    else
      _reason -> :skip
    end
  end

  defp project_notes(project_name) do
    with {:ok, notes} <- Store.Project.Notes.read(project_name) do
      case String.trim(notes) do
        "" -> {:error, :no_notes}
        trimmed -> {:ok, String.slice(trimmed, 0, @notes_preview_bytes)}
      end
    end
  end

  defp embeddings_for_notes(project_name, notes) do
    content = ownership_context(project_name, notes)
    Indexer.impl().get_embeddings(content)
  end

  defp compatible_embeddings?(candidate_embeddings, project_embeddings) do
    embeddings_vector?(candidate_embeddings) and
      embeddings_vector?(project_embeddings) and
      length(candidate_embeddings) == length(project_embeddings)
  end

  defp embeddings_vector?(embeddings), do: is_list(embeddings)

  defp ownership_context(project_name, notes) do
    [
      "Project: #{project_name}",
      "Project notes:",
      notes,
      "Project home: #{Settings.get_user_home()}/#{project_name}"
    ]
    |> Enum.join("\n\n")
  end

  defp choose_winner([winner | rest]) do
    runner_up_score = runner_up_score(rest)
    margin = winner.score - runner_up_score

    choose_winner(winner, margin)
  end

  defp choose_winner([]), do: :inconclusive

  defp choose_winner(winner, margin)
       when winner.score >= @min_project_match_score and margin >= @min_project_match_margin do
    {:ok,
     %{
       project: winner.project,
       score: winner.score,
       margin: margin,
       confident: true
     }}
  end

  defp choose_winner(_winner, _margin), do: :inconclusive

  defp runner_up_score([%{score: score} | _]), do: score

  defp runner_up_score([]), do: 0.0

  defp save_into_project(memory, project_name) do
    moved =
      memory
      |> Map.put(:scope, :project)
      |> Map.put(:embeddings, nil)

    case Memory.Project.save_into(project_name, moved) do
      :ok -> {:ok, moved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp memory_text(%Memory{} = memory) do
    [memory.title, memory.content | List.wrap(memory.topics)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join("\n\n")
  end

  defp mentions_code_identifier?(text) do
    String.contains?(text, "`") or Regex.match?(~r/[A-Z][A-Za-z0-9_]+\.[A-Za-z0-9_]+/, text)
  end

  defp mentions_file_path?(text) do
    Regex.match?(~r/(^|\s)(lib|test|config|docs|scratch)\//, text)
  end

  defp mentions_cli_or_workflow_term?(text) do
    Enum.any?(
      [
        "mix ",
        "fnord ",
        "branch",
        "ticket",
        "deploy",
        "workflow",
        "module",
        "component"
      ],
      &String.contains?(String.downcase(text), &1)
    )
  end

  defp mentions_projectish_tokens?(text) do
    Regex.match?(~r/\b(cmd|memory|consolidator|file_store|project|global|session)\b/i, text)
  end
end
