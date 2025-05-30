defmodule AI.Tools.Git.Grep do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(args), do: {"Git grep", args["pattern"]}

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(%{"pattern" => regex}), do: {:ok, %{"pattern" => regex}}
  def read_args(_args), do: AI.Tools.required_arg_error("pattern")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_grep_tool",
        description: """
        Searches the git repository for a pattern using `git grep`. This tool
        is useful for finding all instances of a pattern in the codebase.
        """,
        parameters: %{
          type: "object",
          required: ["pattern"],
          properties: %{
            pattern: %{
              type: "string",
              description: "The regex or string pattern to search for in the git repository."
            },
            ignore_case: %{
              type: "boolean",
              description: "Whether to ignore case when searching for the pattern.",
              default: false
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, pattern} <- Map.fetch(args, "pattern") do
      ignore_case = Map.get(args, "ignore_case", false)

      case Git.grep(pattern, ignore_case) do
        {:ok, output} -> {:ok, "[git_grep_tool]\n#{output}"}
        {:error, output} -> {:ok, "[git_grep_tool]\n#{output}"}
      end
    end
  end
end
