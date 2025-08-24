# lib/git_cli.ex

defmodule GitCli do
  @moduledoc """
  Wrapper for direct git CLI calls. Provides helper functions for repo checks,
  formatted info messages, and listing ignored files in a given root.
  """

  @spec is_git_repo?() :: boolean()
  def is_git_repo? do
    System.find_executable("git") != nil and File.dir?(".git")
  end

  @spec git_info() :: String.t()
  def git_info() do
    git = System.find_executable("git")

    if git do
      cwd = File.cwd!()

      root =
        case System.cmd(git, ["rev-parse", "--show-toplevel"], cd: cwd, stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end

      branch =
        if root do
          case System.cmd(git, ["rev-parse", "--abbrev-ref", "HEAD"],
                 cd: root,
                 stderr_to_stdout: true
               ) do
            {out, 0} -> String.trim(out)
            _ -> nil
          end
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

  @spec ignored_files(String.t()) :: map()
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
