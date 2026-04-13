# lib/git_cli.ex

defmodule GitCli do
  @moduledoc """
  Wrapper for direct git CLI calls. Provides helper functions for repo checks,
  formatted info messages, and listing ignored files in a given root.
  """

  @spec is_git_repo?() :: boolean()
  def is_git_repo? do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: effective_git_dir(),
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  @spec is_git_repo_at?(String.t() | nil) :: boolean()
  def is_git_repo_at?(nil), do: false

  def is_git_repo_at?(path) when is_binary(path) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  def repo_root() do
    git = System.find_executable("git")

    if git do
      case System.cmd(git, ["rev-parse", "--show-toplevel"],
             cd: effective_git_dir(),
             stderr_to_stdout: true
           ) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end
    else
      nil
    end
  end

  # We currently treat any effective directory inside a git working tree as
  # worktree-aware enough for callers using this predicate, including detached
  # HEAD state.
  def is_worktree? do
    is_git_repo?()
  end

  def worktree_root() do
    if is_worktree?() do
      case System.cmd("git", ["rev-parse", "--show-toplevel"],
             cd: effective_git_dir(),
             stderr_to_stdout: true
           ) do
        {result, 0} -> String.trim(result)
        _ -> nil
      end
    else
      nil
    end
  end

  # Branch reporting follows the same effective directory semantics as the
  # other repo and worktree helpers in this module.
  @spec current_branch() :: String.t() | nil
  def current_branch() do
    git = System.find_executable("git")

    if git do
      case System.cmd(git, ["rev-parse", "--abbrev-ref", "HEAD"],
             cd: effective_git_dir(),
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          case String.trim(out) do
            "HEAD" ->
              case System.cmd(git, ["rev-parse", "--short", "HEAD"],
                     cd: effective_git_dir(),
                     stderr_to_stdout: true
                   ) do
                {sha, 0} -> "@" <> String.trim(sha)
                _ -> nil
              end

            branch ->
              branch
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  @spec branch_name(String.t(), String.t()) :: String.t() | nil
  defp branch_name(git, dir) do
    case System.cmd(git, ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.trim(out) do
          "HEAD" ->
            case System.cmd(git, ["rev-parse", "--short", "HEAD"],
                   cd: dir,
                   stderr_to_stdout: true
                 ) do
              {sha, 0} -> "@" <> String.trim(sha)
              _ -> nil
            end

          branch ->
            branch
        end

      _ ->
        nil
    end
  end

  @spec git_info() :: String.t()
  def git_info() do
    git = System.find_executable("git")

    if git do
      root =
        case System.cmd(git, ["rev-parse", "--show-toplevel"],
               cd: effective_git_dir(),
               stderr_to_stdout: true
             ) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end

      branch =
        if root do
          branch_name(git, effective_git_dir())
        end

      if root && branch do
        """
        You are working in a git repository.
        The current branch is `#{branch}`.
        The git root is `#{root}`.
        """
      else
        "Note: this project is not under git version control."
      end
    else
      "Note: git executable not found on PATH."
    end
  end

  @spec effective_git_dir() :: String.t()
  defp effective_git_dir() do
    Settings.get_project_root_override() || File.cwd!()
  end

  @spec ignored_files(String.t() | nil) :: map()
  @doc """
  Returns an empty map if root is nil, otherwise behaves as before.
  """
  def ignored_files(nil), do: %{}

  def ignored_files(root) when is_binary(root) do
    case System.cmd("git", ["ls-files", "--others", "--ignored", "--exclude-standard"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&Path.absname(&1, root))
        |> Map.new(&{&1, true})

      _ ->
        %{}
    end
  end
end
