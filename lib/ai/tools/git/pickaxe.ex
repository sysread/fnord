defmodule AI.Tools.Git.Pickaxe do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(args), do: {"Archaeologizing", args["regex"]}

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_pickaxe_tool",
        description: """
        Searches git history for commits that include the supplied regex. This
        is useful to identify when an entity was added or removed from the code
        base, when a bug might have been introduced, or to confirm that
        apparently orphaned code is no longer in use.

        This tool utilizes `git log -G`, so any changes matching your regex are
        returned, not just those that added or removed the term.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
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
    with {:ok, regex} <- Map.fetch(args, "regex") do
      case Git.pickaxe_regex(regex) do
        {:ok, output} -> {:ok, "[git_pickaxe_tool]\n#{output}"}
        {:error, output} -> {:ok, "[git_pickaxe_tool]\n#{output}"}
      end
    end
  end
end
