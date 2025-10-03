defmodule Fnord.ResolveProject do
  @moduledoc """
  Project resolution from cwd or git worktree root.

  Normalizes paths, applies robust containment, and chooses the deepest matching
  project when roots nest. Returns {:ok, project_name} or {:error, :not_in_project}.
  """

  @type project_name :: binary

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

    matching_projects =
      projects
      |> Enum.filter(fn {root_abs, _name} -> path_contains?(root_abs, cwd_abs) end)

    case matching_projects do
      [] ->
        {:error, :not_in_project}

      _ ->
        {_, project_name} =
          Enum.max_by(matching_projects, fn {root_abs, _} -> String.length(root_abs) end)

        {:ok, project_name}
    end
  end

  @spec resolve_from_worktree() :: {:ok, project_name} | {:error, :not_in_project}
  def resolve_from_worktree() do
    # Gather possible roots from git worktree and repo
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

    # Attempt direct match of candidate to configured roots
    case Enum.find(candidates, fn candidate ->
           Enum.any?(projects, fn {root_abs, _} -> root_abs == candidate end)
         end) do
      nil ->
        # Fall back to resolve_from_cwd for each candidate
        candidates
        |> Enum.reduce_while(nil, fn cand, _ ->
          case resolve_from_cwd(cand) do
            {:ok, name} -> {:halt, {:ok, name}}
            _ -> {:cont, nil}
          end
        end)
        |> case do
          {:ok, _} = ok -> ok
          _ -> {:error, :not_in_project}
        end

      matched ->
        # Return the project matching the candidate root
        {_, name} = Enum.find(projects, fn {root_abs, _} -> root_abs == matched end)
        {:ok, name}
    end
  end

  # Determines if `child` is equal to or contained within `parent`.
  defp path_contains?(parent, child) do
    parent_sep =
      parent
      |> Path.expand()
      |> Path.join("")

    child_sep =
      child
      |> Path.expand()
      |> Path.join("")

    String.starts_with?(child_sep, parent_sep)
  end
end
