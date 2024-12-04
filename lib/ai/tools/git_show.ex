defmodule AI.Tools.GitShow do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_show_tool",
        description: """
        Retrieves the commit message and diff for a given commit SHA. This is
        usefl to determine when a bug might have been introduced, or to confirm
        that seemingly orphaned code is no longer in use.
        """,
        parameters: %{
          type: "object",
          required: ["sha"],
          properties: %{
            sha: %{
              type: "string",
              description: """
              The SHA of the commit to retrieve. It may be either the full SHA
              or a short SHA.
              """
            },
            file: %{
              type: "string",
              description: """
              Optionally, you can include a file path. This changes the
              behavior of the tool to show you the complete file at a given
              commit, rather than showing you the commit message and diff. This
              is equivalent to `git show $sha:$file`.

              To see the current version of the file, use the sha `HEAD`.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, sha} <- Map.fetch(args, "sha") do
      file = Map.get(args, "file", nil)

      case show(sha, file) do
        {:ok, output} -> {:ok, "[git_show]\n#{output}"}
        {:error, output} -> {:ok, "[git_show]\n#{output}"}
      end
    end
  end

  defp show(sha, nil), do: Git.show(sha)
  defp show(sha, file), do: Git.show(sha, file)
end
