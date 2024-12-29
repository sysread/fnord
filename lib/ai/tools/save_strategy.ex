defmodule AI.Tools.SaveStrategy do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "save_strategy_tool",
        description: """
        "Research Strategies" are previously saved prompts that can be used to
        guide the research strategy of the orchestrating AI agent.

        This tool saves a new research strategy or updates an existing one. If
        you want to update an existing strategy, you must include the ID of the
        strategy exactly as it was provided by the search_strategies_tool. This
        parameter should be left out when saving a new strategy.

        Research strategies should ALWAYS be general enough to apply to all
        software projects, not just the currently selected one. They should be
        100% orthogonal to the project, language, or domain.
        """,
        parameters: %{
          type: "object",
          required: ["title", "prompt", "questions"],
          properties: %{
            id: %{
              type: "string",
              description: """
              Existing strategies identified by the search_strategies_tool may be updated by providing the ID of the strategy to update.
              The ID is provided by the search_strategies_tool.
              """
            },
            title: %{
              type: "string",
              description: """
              A very brief label for the research strategy.
              This should be completely orthogonal to any specific project or the details of the user's current query.
              Examples:
              - "Identify the root cause of a bug based on a stack trace"
              - "Create documentation for an undocumented module"
              - "Steps to refactor a legacy module"
              - "Identify the commit that introduced a bug"
              """
            },
            prompt: %{
              type: "string",
              description: """
              The prompt text of the research strategy.
              Prompts should be concise, project-agnostic, and define a *research strategy* that can be followed to solve a class of problems.
              This prompt will be used to guide the orchestrating AI agent in its research.
              This should be completely orthogonal to any specific project or the details of the user's current query.
              Instead, attempt to create a generalized prompt that instructs the orchestrating AI agent on how to proceed with research for this class of problem.
              """
            },
            questions: %{
              type: "array",
              items: %{type: "string"},
              description: """
              Provide a list of example questions for which this research strategy is appropriate to solve.
              This should be completely orthogonal to any specific project or the details of the user's current query.
              Instead, attempt to create generalized questions whose solution would be optimally identified by this class of research strategy.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, title} <- Map.fetch(args, "title"),
         {:ok, prompt} <- Map.fetch(args, "prompt"),
         {:ok, questions} <- Map.fetch(args, "questions") do
      args
      |> Map.get("id", nil)
      |> Store.Prompt.new()
      |> Store.Prompt.write(title, prompt, questions)

      {:ok, "Research strategy saved successfully."}
    end
  end
end
