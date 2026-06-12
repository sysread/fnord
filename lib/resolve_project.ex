# This module determines the current project based on the current working directory
# or falls back to git worktree and repository roots to ensure the most specific project
# context is identified.
defmodule ResolveProject do
  @moduledoc """
  Project resolution from the current working directory.

  Behavior:
  - With no explicit cwd, the effective directory is the session's project
    root override (`Settings.get_project_root_override/0`) when set, else
    the real cwd. In prod the override is always nil at resolution time;
    see the comment in `resolve/1`.
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
      |> Enum.flat_map(fn
        {name, %{"root" => nil}} ->
          UI.warn("Project '#{name}' missing 'root' configuration, skipping.")
          []

        {name, %{"root" => root}} ->
          [{Path.absname(root), name}]

        {name, _project_config} ->
          UI.warn("Project '#{name}' missing 'root' configuration, skipping.")
          []
      end)

    # Resolution base: an explicit cwd argument wins; otherwise honor the
    # session's project-root override before falling back to the real cwd.
    # In prod the override is always nil here - resolution runs once at CLI
    # parse time, and every override writer (ask's worktree machinery) runs
    # later - so consulting it changes nothing today. It exists for
    # consistency (if resolution ever re-runs with an override set, the
    # worktree mapping below converges on the same project) and as the
    # async-safe alternative to File.cd! in tests.
    base_dir =
      case cwd do
        nil -> Settings.get_project_root_override() || File.cwd!()
        dir -> dir
      end

    # If we are inside a git worktree, prefer resolving at the primary repo
    # root so that project selection reflects the clone from which the
    # worktree was created. Skipped when an explicit cwd was passed,
    # preserving resolve/1's literal-directory contract for that form.
    repo_root_in_ctx =
      case cwd do
        nil -> GitCli.primary_root_at(base_dir)
        _ -> nil
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
