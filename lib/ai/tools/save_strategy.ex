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

        The research strategy is composed of 3 components. The first is a short
        title describing the strategy (e.g. "How do implement a code artifact
        when the the user's terminology may refer to multiple concepts" or "How
        to trace the origin of a bug across multiple apps in a monorepo"). The
        second is the prompt that will guide the AI agent in performing its
        research. Finally, you must include a list of example user queries for
        which this prompt is appropriate. The example queries will become the
        primary basis for the search_strategies_tool to identify this strategy
        in the future.
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
      Map.get(args, "id", nil)
      |> case do
        nil -> Store.Prompt.new()
        id -> Store.Prompt.new(id)
      end
      |> Store.Prompt.write(title, prompt, questions)
      |> case do
        {:ok, _prompt} -> {:ok, "Strategy saved successfully."}
        {:error, _reason} -> {:error, "Failed to save strategy: #{inspect(args)}"}
      end
    end
  end
end
