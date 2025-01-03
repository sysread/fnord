defmodule AI.Tools.PriorResearch do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"query" => query}) do
    {"Searching the archives for prior research", "#{query}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"query" => query}, result) do
    {"Prior research identified from the archives", "#{query}\n#{result}"}
  end

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "prior_research_tool",
        description: "",
        parameters: %{
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: """
              Request information from the Archivist Agent related to the
              user's needs and the research task being performed.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, query} <- Map.fetch(args, "query") do
      AI.Agent.Archivist.get_response(agent.ai, %{query: query})
    end
  end
end
