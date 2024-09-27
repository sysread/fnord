defmodule Git do
  def is_ignored?(file) do
    case System.cmd("git", ["check-ignore", file], stderr_to_stdout: true, parallelism: true) do
      {_, 0} -> true
      {_, _} -> false
    end
  end
end
