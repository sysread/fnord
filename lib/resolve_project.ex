# This module determines the current project based on the current working directory
# or falls back to git worktree and repository roots to ensure the most specific project
# context is identified.
defmodule ResolveProject do
  @moduledoc """
  Project resolution from the current working directory.

  Behavior:
  - If inside a git worktree, `resolve/1` will map the cwd to the repository root.
  - Select the configured project whose root contains that directory, choosing the one with the deepest (longest) root path.

  Returns `{:ok, project_name}` or `{:error, :not_in_project}`.
  """

  @type project_name :: binary

  # Find the configured project whose root most specifically contains the provided directory.
  @spec resolve(cwd :: binary | nil) :: {:ok, project_name} | {:error, :not_in_project}
  def resolve(cwd \\ nil) do
    projects =
      Settings.new()
      |> Settings.get_projects()
      |> Enum.flat_map(fn {name, %{"root" => root}} ->
        case root do
          nil -> []
          root_str -> [{Path.absname(root_str), name}]
        end
      end)

    # If we are inside a git worktree, prefer resolving at the primary repo root
    # so that project selection reflects the clone from which the worktree was created.
    base_dir =
      case cwd do
        nil -> File.cwd!()
        dir -> dir
      end

    repo_root_in_ctx =
      case cwd do
        nil ->
          case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
                 cd: base_dir,
                 stderr_to_stdout: true
               ) do
            {"true\n", 0} ->
              case System.cmd("git", ["rev-parse", "--git-common-dir"],
                     cd: base_dir,
                     stderr_to_stdout: true
                   ) do
                {out, 0} ->
                  out
                  |> String.trim()
                  |> Path.dirname()

                _ ->
                  nil
              end

            _ ->
              nil
          end

        _ ->
          nil
      end

    cwd_base = repo_root_in_ctx || base_dir

    cwd_abs = Path.absname(cwd_base)

    # Filter to projects whose root contains the current working directory.
    matching_projects =
      projects
      |> Enum.filter(fn {root_abs, _name} -> Util.path_within_root?(cwd_abs, root_abs) end)

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
end
