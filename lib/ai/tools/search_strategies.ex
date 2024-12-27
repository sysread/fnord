defmodule AI.Tools.SearchStrategies do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "search_strategies_tool",
        description: """
        "Research Strategies" are previously saved prompts that can be used to
        guide the research strategy of the orchestrating AI agent.

        This tool performs a semantic search of your saved research strategies.
        Returns up to 3 matching strategies' title, ID, and prompt. The ID may
        be used to update the strategy later.

        It is up to **you** to decide which strategy is most appropriate for
        the user's query and/or to optionally customize it for the user's
        current query.

        After providing the strategy to the orchestrating AI agent, you may
        elect to use the `save_strategy_tool` to refine the strategy by
        improving the prompt, title, or example questions.
        """,
        parameters: %{
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: """
              The search query to use for the search. This will be matched
              against example user queries that could be answered using the
              identified research strategy.

              Avoid including project-specific terms or details in your query.
              Instead, focus on the CLASS of problem you are trying to solve.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, query} <- Map.fetch(args, "query") do
      query
      |> Store.Prompt.search()
      |> Enum.reduce([], fn {_score, prompt}, acc ->
        with {:ok, info} <- Store.Prompt.read(prompt) do
          [
            """
            # #{info.title}
            - **ID:** #{prompt.id}
            ```
            #{info.prompt}
            ```
            """
            | acc
          ]
        else
          _ -> acc
        end
      end)
      |> Enum.reverse()
      |> Enum.join("\n-----\n")
      |> then(&{:ok, &1})
    end
  end
end
