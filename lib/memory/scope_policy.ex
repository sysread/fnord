defmodule Memory.ScopePolicy do
  @moduledoc """
  Centralizes scope rules for long-term memories.

  This module is the integration point where the system decides whether a
  memory may live in a given long-term scope and whether automatic scope
  transitions are allowed. The indexer and consolidator both consult these
  rules so that special cases are enforced in code rather than left to prompt
  wording or ad hoc heuristics.
  """

  @reserved_global_titles ["Me"]
  @long_term_scopes [:global, :project]

  @doc """
  Returns true when the title identifies a reserved long-term memory.
  """
  @spec reserved_title?(String.t()) :: boolean()
  def reserved_title?(title) when is_binary(title) do
    title in @reserved_global_titles
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
  Returns true when the memory may be moved automatically from one scope to
  another.

  Automatic scope moves are intentionally narrower than general scope validity.
  A memory may be valid in a scope without being eligible for unattended moves.
  """
  @spec allow_automatic_move?(Memory.t(), Memory.scope()) :: boolean()
  def allow_automatic_move?(%Memory{} = memory, target_scope) do
    case {memory.scope, target_scope, valid_target_scope?(memory, target_scope)} do
      {:global, :project, true} -> true
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
  Returns true when the target title and scope form a valid long-term action
  target.
  """
  @spec valid_long_term_target?(String.t(), String.t() | atom()) :: boolean()
  def valid_long_term_target?(title, scope) when is_binary(title) do
    validate_scope(%Memory{title: title}, scope) == :ok
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
