defmodule AI.Tools.GitPickaxeRegex do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_pickaxe_regex_tool",
        description: """
        Searches git history for commits that include the supplied regex. This
        is useful to identify when an entity was added or removed from the code
        base, determine when a bug might have been introduced, or to confirm
        that seemingly orphaned code is no longer in use (when combined with
        the search_tool).

        This differs from the git_pickaxe_term_tool in that it uses `git log
        -G`, so ANY changes matching your regex are returned, not just those
        that added or removed the term.
        """,
        parameters: %{
          type: "object",
          required: ["regex"],
          properties: %{
            regex: %{
              type: "string",
              description: "The regex to search for in the git history (using `git log -G`)."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, regex} <- Map.fetch(args, "regex"),
         {:ok, root} <- Settings.new() |> Settings.get_root() do
      case Git.pickaxe_regex(root, regex) do
        {:ok, output} -> {:ok, "[git_pickaxe_regex_tool]\n#{output}"}
        {:error, output} -> {:ok, "[git_pickaxe_regex_tool]\n#{output}"}
      end
    end
  end
end
