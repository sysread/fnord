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
  def call(agent, args) do
    with {:ok, sha} <- Map.fetch(args, "sha"),
         {:ok, %{"root" => root}} <- get_root(agent.opts.project) do
      file = Map.get(args, "file", nil)
      status_id = Tui.add_step("Inspecting commit", sha)

      case show(root, sha, file) do
        {:ok, output} ->
          Tui.finish_step(status_id, :ok)
          {:ok, "[git_show]\n#{output}"}

        {:error, output} ->
          Tui.finish_step(status_id, :error)
          Tui.warn("git_show error", output)
          {:ok, "[git_show]\n#{output}"}
      end
    end
  end

  defp get_root(project), do: Settings.new() |> Settings.get_project(project)

  defp show(root, sha, nil), do: Git.show(root, sha)
  defp show(root, sha, file), do: Git.show(root, sha, file)
end
