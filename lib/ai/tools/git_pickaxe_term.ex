defmodule AI.Tools.GitPickaxeTerm do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_pickaxe_term_tool",
        description: """
        Searches git history for commits that include the supplied term. This
        is useful to identify when an entity was added or removed from the code
        base, determine when a bug might have been introduced, or to confirm
        that seemingly orphaned code is no longer in use (when combined with
        the search_tool).
        """,
        parameters: %{
          type: "object",
          required: ["term"],
          properties: %{
            term: %{
              type: "string",
              description: "The term to search for in the git history (using `git log -S`)."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, term} <- Map.fetch(args, "term"),
         {:ok, %{"root" => root}} <- get_root(agent.opts.project) do
      case Git.pickaxe_term(root, term) do
        {:ok, output} -> {:ok, "[git_pickaxe_term_tool]\n#{output}"}
        {:error, output} -> {:ok, "[git_pickaxe_term_tool]\n#{output}"}
      end
    end
  end

  defp get_root(project) do
    Settings.new()
    |> Settings.get_project(project)
  end
end
