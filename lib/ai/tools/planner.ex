defmodule AI.Tools.Planner do
  require Logger

  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "planner_tool",
        description: "analyze the conversation and suggest the next steps",
        parameters: %{
          type: "object",
          required: [],
          properties: %{}
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, _args) do
    Logger.info("[planner] examining findings and planning the next steps")

    agent
    |> AI.Agent.Planner.new()
    |> AI.Agent.Planner.get_suggestion()
    |> then(fn
      {:ok, suggestion} ->
        Logger.debug("[planner]: #{suggestion}")
        {:ok, "[planner_tool]\n#{suggestion}"}

      {:error, reason} ->
        Logger.error("[planner] error getting suggestion: #{reason}")
        {:error, reason}
    end)
  end
end
