defmodule AI.Tools.GitDiffBranch do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"topic" => topic} = args) do
    base = Map.get(args, "base", "origin/main")
    {"Diffing branches", "Diffing branches #{base}..#{topic}"}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_diff_branch_tool",
        description: """
        Diffs two branches and returns a list of the commits in the branch as
        well as the diff of changes between $topic and $base. If $base is not
        provided, it defaults to `origin/main`. Note that this *always* uses
        the `origin/` prefix for the branches. If the user did not prefix the
        branch with `origin/`, you should note that detail to them.
        """,
        parameters: %{
          type: "object",
          required: ["topic"],
          properties: %{
            topic: %{
              type: "string",
              description: """
              The topic branch to diff. Note that this *will* be prefixed with
              `origin/`.
              """
            },
            base: %{
              type: "string",
              description: """
              The base branch to diff against. If not provided, it defaults to
              `origin/main`.
              """,
              default: "origin/main"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, topic} <- Map.fetch(args, "topic") do
      base = Map.get(args, "base", "origin/main")

      case Git.diff_branch(topic, base) do
        {:ok, {commits, changes}} -> {:ok, "[git_diff_branch]\n#{commits}\n\n#{changes}"}
        {:error, output} -> {:ok, "[git_diff_branch]\n#{output}"}
      end
    end
  end
end
