defmodule AI.Tools.Strategies.Search do
  @moduledoc """
  This tool performs a semantic search of the strategies saved in the store.
  Those strategies come from `data/strategies.yaml`, which is read at compile
  in `Store.Strategy` and installed into `$HOME/.fnord/strategies`.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"query" => query}) do
    {"Searching for research strategies", query}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    titles =
      result
      |> Jason.decode!()
      |> Enum.map(fn %{"title" => title} -> "- #{title}" end)
      |> Enum.join("\n")

    {"Identified possible research strategies", "\n#{titles}"}
  end

  @impl AI.Tools
  def read_args(%{"query" => query}), do: {:ok, %{"query" => query}}
  def read_args(_args), do: AI.Tools.required_arg_error("query")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "strategies_search_tool",
        description: """
        "Research Strategies" are research plans that can be used to guide the
        research strategy of the orchestrating AI agent. Research Strategies
        are agnostic to the project and the context of the user's query,
        instead focusing on the process to follow when researching specific
        classes of problems.

        This tool performs a semantic search of your saved research strategies.
        Returns up to 10 matching strategies' title and prompt.

        It is up to **YOU** to decide which strategy is most appropriate for
        the user's query and to adapt it for the specific context.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
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
  def call(_completion, args) do
    with {:ok, query} <- Map.fetch(args, "query") do
      query
      |> Store.search_strategies()
      |> Enum.reduce([], fn {score, prompt}, acc ->
        with {:ok, info} <- Store.Strategy.read(prompt) do
          data = %{
            title: info.title,
            prompt: info.prompt,
            match_score: score
          }

          [data | acc]
        end
      end)
      |> Enum.reverse()
      |> then(&{:ok, &1})
    end
  end
end
