defmodule Git do
  @moduledoc """
  Module for interacting with git.
  """

  @doc """
  Check if a file is ignored by git.
  """
  def is_ignored?(file, git_root) do
    case System.cmd("git", ["-C", git_root, "check-ignore", file],
           stderr_to_stdout: true,
           parallelism: true,
           env: [
             {"GIT_TRACE", "0"},
             {"GIT_CURL_VERBOSE", "0"},
             {"GIT_DEBUG", "0"}
           ]
         ) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

  def pickaxe_term(git_root, term) do
    case System.cmd("git", ["-C", git_root, "log", "-S", term],
           stderr_to_stdout: true,
           parallelism: true,
           env: [
             {"GIT_TRACE", "0"},
             {"GIT_CURL_VERBOSE", "0"},
             {"GIT_DEBUG", "0"}
           ]
         ) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  def pickaxe_regex(git_root, regex) do
    case System.cmd("git", ["-C", git_root, "log", "-G", regex],
           stderr_to_stdout: true,
           parallelism: true,
           env: [
             {"GIT_TRACE", "0"},
             {"GIT_CURL_VERBOSE", "0"},
             {"GIT_DEBUG", "0"}
           ]
         ) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  def show(git_root, sha) do
    case System.cmd("git", ["-C", git_root, "show", sha],
           stderr_to_stdout: true,
           parallelism: true,
           env: [
             {"GIT_TRACE", "0"},
             {"GIT_CURL_VERBOSE", "0"},
             {"GIT_DEBUG", "0"}
           ]
         ) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  def show(git_root, sha, file) do
    # Make file relative to git root
    file = Path.relative_to(file, git_root)

    case System.cmd("git", ["-C", git_root, "show", "#{sha}:#{file}"],
           stderr_to_stdout: true,
           parallelism: true,
           env: [
             {"GIT_TRACE", "0"},
             {"GIT_CURL_VERBOSE", "0"},
             {"GIT_DEBUG", "0"}
           ]
         ) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end
end
