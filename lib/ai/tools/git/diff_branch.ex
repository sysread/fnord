defmodule AI.Tools.Git.DiffBranch do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: Git.is_available?()

  @impl AI.Tools
  def ui_note_on_request(%{"topic" => topic} = args) do
    base = Map.get(args, "base", "origin/main")
    {"Diffing branches", "Diffing branches #{base}..#{topic}"}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(args) do
    with {:ok, topic} <- read_topic(args) do
      base = Map.get(args, "base", "origin/main")
      {:ok, %{"topic" => topic, "base" => base}}
    end
  end

  defp read_topic(%{"topic" => topic}), do: {:ok, topic}
  defp read_topic(_args), do: AI.Tools.required_arg_error("topic")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_diff_branch_tool",
        description: """
        Diffs two branches and returns a list of the commits in the branch as
        well as the diff of changes between $topic and $base. If $base is not
        provided, it defaults to `origin/main`.
        """,
        parameters: %{
          type: "object",
          required: ["topic"],
          properties: %{
            topic: %{
              type: "string",
              description: "The topic branch to diff (will be prefixed with `origin/`"
            },
            base: %{
              type: "string",
              description: "The base branch to diff against (default: `origin/main`)",
              default: "origin/main"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, topic} <- Map.fetch(args, "topic") do
      base = Map.get(args, "base", "origin/main")

      case Git.diff_branch(topic, base) do
        {:ok, {commits, changes}} -> {:ok, "[git_diff_branch]\n#{commits}\n\n#{changes}"}
        {:error, output} -> {:ok, "[git_diff_branch]\n#{output}"}
      end
    end
  end
end
