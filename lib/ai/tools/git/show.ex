defmodule AI.Tools.Git.Show do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(args), do: {"Inspecting commit", args["sha"]}

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(args) do
    with {:ok, sha} <- get_sha(args) do
      file = Map.get(args, "file", nil)
      {:ok, %{"sha" => sha, "file" => file}}
    end
  end

  defp get_sha(%{"sha" => sha}), do: {:ok, sha}
  defp get_sha(_args), do: AI.Tools.required_arg_error("sha")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_show_tool",
        description: """
        Retrieves the commit message and diff for a given commit SHA. This tool
        may also be used to view the raw contents of a file at a specific
        commit. Use HEAD to get the currently checked out version. This is
        equivalent to `git show $sha:$file`.
        """,
        parameters: %{
          type: "object",
          required: ["sha"],
          properties: %{
            sha: %{
              type: "string",
              description: """
              The SHA of the commit to retrieve. It may be either the full SHA
              or a short SHA, a branch name, HEAD, or any other valid git
              reference that `git show` can resolve.
              """
            },
            file: %{
              type: "string",
              description: """
              Optional file path. This changes the behavior of the tool to show
              you the complete file at a given commit instead of the commit
              message and diff. This is equivalent to `git show $sha:$file`.

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
