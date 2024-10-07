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
           parallelism: true
         ) do
      {_, 0} -> true
      {_, _} -> false
    end
  end
end
