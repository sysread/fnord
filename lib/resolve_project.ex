# This module determines the current project based on the current working directory
# or falls back to git worktree and repository roots to ensure the most specific project
# context is identified.
defmodule ResolveProject do
  @moduledoc """
  Project resolution from cwd or git worktree root.

  Resolution order (most-specific to least-specific):
  - From CWD: choose the configured project whose root contains CWD with the deepest (longest) root.
  - Git fallback: build candidate roots from worktree and repo.
    - Prefer exact matches first (worktree exact beats repo exact; ties break by depth then name).
    - Otherwise, pick the deepest configured project whose root lies within any candidate (ties by name).

  Returns `{:ok, project_name}` or `{:error, :not_in_project}`.
  """

  @type project_name :: binary

  # Find the configured project whose root most specifically contains the provided directory.
  @spec resolve_from_cwd(cwd :: binary | nil) :: {:ok, project_name} | {:error, :not_in_project}
  def resolve_from_cwd(cwd \\ nil) do
    projects =
      Settings.new()
      |> Settings.get_projects()
      |> Enum.flat_map(fn {name, %{"root" => root}} ->
        case root do
          nil -> []
          root_str -> [{Path.absname(root_str), name}]
        end
      end)

    cwd_abs =
      case cwd do
        nil -> Path.absname(File.cwd!())
        dir -> Path.absname(dir)
      end

    # Filter to projects whose root contains the current working directory.
    matching_projects =
      projects
      |> Enum.filter(fn {root_abs, _name} -> path_contains?(root_abs, cwd_abs) end)

    # Decide outcome based on whether any matching projects were found.
    case matching_projects do
      # No matching project roots found, return error.
      [] ->
        {:error, :not_in_project}

      # Select the project with the deepest root path as the most specific match.
      _ ->
        {_, project_name} =
          Enum.max_by(matching_projects, fn {root_abs, _} -> String.length(root_abs) end)

        {:ok, project_name}
    end
  end

  # Fall back to git worktree and repo roots when cwd-based resolution fails.
  @spec resolve_from_worktree() :: {:ok, project_name} | {:error, :not_in_project}
  def resolve_from_worktree() do
    # Gather unique candidate roots from git worktree and repository.
    candidates =
      [GitCli.worktree_root(), GitCli.repo_root()]
      |> Enum.filter(& &1)
      |> Enum.map(&Path.absname/1)
      |> Enum.uniq()

    # Load configured project roots
    projects =
      Settings.new()
      |> Settings.get_projects()
      |> Enum.flat_map(fn {name, %{"root" => root}} ->
        case root do
          nil -> []
          root_str -> [{Path.absname(root_str), name}]
        end
      end)

    # Phase 1: attempt exact matches between configured roots and git candidates.
    selected =
      projects
      |> Enum.filter(fn {root_abs, _} -> root_abs in candidates end)

    result =
      if selected != [] do
        worktree_abs = GitCli.worktree_root() && Path.absname(GitCli.worktree_root())
        repo_abs = GitCli.repo_root() && Path.absname(GitCli.repo_root())

        # Prioritize exact worktree match, then repo exact, then deepest path tie-break for deterministic result
        cond do
          # Prefer explicit worktree because it's the user's active checkout
          worktree_abs && Enum.any?(selected, fn {root_abs, _} -> root_abs == worktree_abs end) ->
            {_, name} = Enum.find(selected, fn {root_abs, _} -> root_abs == worktree_abs end)
            {:ok, name}

          # Repo exact is next-strongest explicit anchor
          repo_abs && Enum.any?(selected, fn {root_abs, _} -> root_abs == repo_abs end) ->
            {_, name} = Enum.find(selected, fn {root_abs, _} -> root_abs == repo_abs end)
            {:ok, name}

          # Otherwise deterministic tie-break by deepest path then name to avoid flakiness
          true ->
            {_, name} =
              Enum.max_by(selected, fn {root_abs, name} -> {String.length(root_abs), name} end)

            {:ok, name}
        end
      else
        # Phase 2: find configured roots nested within any git candidate.
        # Fallback: consider configured roots nested within worktree/repo to support deeper subprojects.
        nested =
          projects
          |> Enum.filter(fn {root_abs, _} ->
            Enum.any?(candidates, fn cand -> Util.path_within_root?(root_abs, cand) end)
          end)

        if nested != [] do
          # Choose the deepest nested project to reflect the most specific context, with name tie-break for determinism
          {_, name} =
            Enum.max_by(nested, fn {root_abs, name} -> {String.length(root_abs), name} end)

          {:ok, name}
        else
          {:error, :not_in_project}
        end
      end

    result
  end

  # Determines if `child` path lies within or equals the `parent` path.
  defp path_contains?(parent, child) do
    parent_abs = Path.expand(parent)
    child_abs = Path.expand(child)
    Util.path_within_root?(child_abs, parent_abs)
  end
end
