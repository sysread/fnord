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
    case GitCli.worktree_root() do
      nil ->
        case GitCli.repo_root() do
          nil -> {:error, :not_in_project}
          root -> resolve_from_cwd(root)
        end

      root ->
        resolve_from_cwd(root)
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
