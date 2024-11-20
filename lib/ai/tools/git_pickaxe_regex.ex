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
  def call(agent, args) do
    with {:ok, regex} <- Map.fetch(args, "regex"),
         {:ok, %{"root" => root}} <- get_root(agent.opts.project) do
      status_id = Tui.add_step("Doing git archaeology", regex)

      case Git.pickaxe_regex(root, regex) do
        {:ok, output} ->
          Tui.finish_step(status_id, :ok)
          {:ok, "[git_pickaxe_regex_tool]\n#{output}"}

        {:error, output} ->
          Tui.finish_step(status_id, :error)
          Tui.warn("git_pickaxe_regex_tool error", output)
          {:ok, "[git_pickaxe_regex_tool]\n#{output}"}
      end
    end
  end

  defp get_root(project) do
    Settings.new()
    |> Settings.get_project(project)
  end
end
