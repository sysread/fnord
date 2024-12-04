defmodule Git do
  @moduledoc """
  Module for interacting with git.
  """

  @common_args [
    stderr_to_stdout: true,
    parallelism: true,
    env: [
      {"GIT_TRACE", "0"},
      {"GIT_CURL_VERBOSE", "0"},
      {"GIT_DEBUG", "0"}
    ]
  ]

  def is_git_repo?() do
    Settings.new()
    |> Settings.get_root()
    |> case do
      {:ok, root} -> is_git_repo?(root)
      _ -> false
    end
  end

  def is_git_repo?(path) do
    case git(path, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, "true"} -> true
      _ -> false
    end
  end

  def is_ignored?(file, git_root) do
    case git(git_root, ["check-ignore", file]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def pickaxe_regex(git_root, regex) do
    git(git_root, ["log", "-G", regex])
  end

  def show(git_root, sha) do
    git(git_root, ["show", sha])
  end

  def show(git_root, sha, file) do
    # Make file relative to git root
    file = Path.relative_to(file, git_root)
    git(git_root, ["show", "#{sha}:#{file}"])
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp git(root, args) do
    args = ["-C", root] ++ args
    git(args)
  end

  defp git(args) do
    case System.cmd("git", args, @common_args) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _} -> {:error, String.trim_trailing(output)}
    end
  end
end
