defmodule AI.Tools.Search do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "search_tool",
        description: "searches for matching files and their contents",
        parameters: %{
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: "The search query string."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, query} <- Map.fetch(args, "query") do
      Ask.update_status("Searching: #{query}")

      AI.Agent.Search.new(agent.ai, agent.opts.question, query, agent.opts)
      |> AI.Agent.Search.search()
      |> case do
        {:ok, results} -> results |> Enum.join("\n\n") |> then(fn res -> {:ok, res} end)
        error -> error
      end
    end
  end
end
