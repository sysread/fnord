defmodule Memory.ScopePolicy do
  @moduledoc """
  Defines long-term scope rules for memories.

  This module decides whether a memory may live in a given long-term scope and
  whether automatic scope transitions are allowed. The indexer and consolidator
  both consult these rules so that scope decisions follow the same policy.
  """

  @reserved_global_titles ["Me"]
  @long_term_scopes [:global, :project]
  @automatic_move_min_signal_count 2

  @doc """
  Returns true when the title identifies a reserved long-term memory.
  """
  @spec reserved_title?(String.t()) :: boolean()
  def reserved_title?(title) when is_binary(title) do
    title in @reserved_global_titles
  end

  @doc """
  Returns true when the memory is reserved from automatic scope moves.
  """
  @spec reserved_from_automatic_move?(Memory.t()) :: boolean()
  def reserved_from_automatic_move?(%Memory{title: title}) do
    reserved_title?(title)
  end

  @doc """
  Returns the allowed long-term scopes for the given title.

  Reserved titles may be pinned to a single scope, while ordinary memories may
  live in either long-term scope.
  """
  @spec allowed_scopes_for_title(String.t()) :: [Memory.scope()]
  def allowed_scopes_for_title(title) when is_binary(title) do
    case title do
      "Me" -> [:global]
      _ -> @long_term_scopes
    end
  end

  @doc """
  Returns true when the memory is allowed to live in the target scope.
  """
  @spec valid_target_scope?(Memory.t(), Memory.scope()) :: boolean()
  def valid_target_scope?(%Memory{title: title}, target_scope) do
    target_scope in allowed_scopes_for_title(title)
  end

  @doc """
  Returns true when the memory has enough project-specific evidence to be
  considered for an automatic move from global to project scope.
  """
  @spec automatic_move_candidate?(Memory.t()) :: boolean()
  def automatic_move_candidate?(%Memory{} = memory) do
    case {global_scope?(memory), reserved_from_automatic_move?(memory)} do
      {true, false} ->
        count_project_signals(memory) >= @automatic_move_min_signal_count

      _ ->
        false
    end
  end

  @doc """
  Returns the number of project-specific signals present across title, content,
  and topics.
  """
  @spec count_project_signals(Memory.t()) :: non_neg_integer()
  def count_project_signals(%Memory{} = memory) do
    [
      project_signal_in_text?(memory.title),
      project_signal_in_text?(memory.content),
      project_signal_in_topics?(memory.topics)
    ]
    |> Enum.count(& &1)
  end

  @doc """
  Returns true when the memory may be moved automatically from one scope to
  another.

  Automatic scope moves are narrower than general scope validity. A memory may
  be valid in a scope without being eligible for an unattended move.
  """
  @spec allow_automatic_move?(Memory.t(), Memory.scope()) :: boolean()
  def allow_automatic_move?(%Memory{} = memory, target_scope) do
    case {memory.scope, target_scope, valid_target_scope?(memory, target_scope)} do
      {:global, :project, true} -> automatic_move_candidate?(memory)
      _ -> false
    end
  end

  @doc """
  Returns :ok when the memory is allowed in the target long-term scope.

  Returns {:error, :project_scope_not_allowed} when the memory is not allowed
  in the requested long-term scope and {:error, :invalid_scope} when the scope
  value cannot be normalized.
  """
  @spec validate_scope(Memory.t(), String.t() | atom()) ::
          :ok | {:error, :project_scope_not_allowed} | {:error, :invalid_scope}
  def validate_scope(%Memory{title: title}, scope) do
    case normalize_scope(scope) do
      {:ok, scope_atom} ->
        allowed_scopes = allowed_scopes_for_title(title)

        case Enum.member?(allowed_scopes, scope_atom) do
          true -> :ok
          false -> {:error, :project_scope_not_allowed}
        end

      :error ->
        {:error, :invalid_scope}
    end
  end

  @doc """
  Returns true when the target title and scope form a valid long-term target.

  Non-binary titles return false.
  """
  @spec valid_long_term_target?(String.t(), String.t() | atom()) :: boolean()
  def valid_long_term_target?(title, scope) when is_binary(title) do
    case normalize_scope(scope) do
      {:ok, scope_atom} -> scope_atom in allowed_scopes_for_title(title)
      :error -> false
    end
  end

  def valid_long_term_target?(_, _), do: false

  defp global_scope?(%Memory{scope: :global}), do: true
  defp global_scope?(%Memory{}), do: false

  defp project_signal_in_topics?(topics) when is_list(topics) do
    Enum.any?(topics, &project_signal_in_text?/1)
  end

  defp project_signal_in_topics?(_), do: false

  defp project_signal_in_text?(text) when is_binary(text) do
    downcased_text = String.downcase(text)

    path_signal?(downcased_text) or
      workflow_term_signal?(downcased_text) or
      code_identifier_signal?(text, downcased_text) or
      scope_token_signal?(downcased_text)
  end

  defp project_signal_in_text?(_), do: false

  defp path_signal?(text) do
    Enum.any?(["lib/", "test/", "config/", "docs/", "scratch/"], &String.contains?(text, &1))
  end

  defp workflow_term_signal?(text) do
    Regex.match?(~r/\bmix\s+/i, text) or
      Regex.match?(~r/\bfnord\s+/i, text) or
      Regex.match?(~r/\b(branch|ticket|deploy|workflow|module|component)\b/i, text)
  end

  defp code_identifier_signal?(original_text, downcased_text) do
    String.contains?(original_text, "`") or
      Regex.match?(
        ~r/\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+(?:\.[a-z_][A-Za-z0-9_]*[!?]?)?\b/,
        original_text
      ) or
      Regex.match?(~r/\b[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*[!?]?\b/, downcased_text)
  end

  defp scope_token_signal?(text) do
    Regex.match?(~r/\b(consolidator|project|global|session)\b/i, text) or
      Regex.match?(
        ~r/\bmemory\b\s*(?:scope|policy|store|index(?:er)?|consolidator|topic|topics|title|content)s?\b/i,
        text
      ) or
      Regex.match?(~r/\bcmd\b\s*[:\/]/i, text) or
      Regex.match?(~r/\bfile_store\b/i, text)
  end

  @doc """
  Normalizes a long-term scope value into an atom.
  """
  @spec normalize_scope(String.t() | atom()) :: {:ok, Memory.scope()} | :error
  def normalize_scope(scope) do
    case scope do
      :global -> {:ok, :global}
      :project -> {:ok, :project}
      "global" -> {:ok, :global}
      "project" -> {:ok, :project}
      _ -> :error
    end
  end
end
