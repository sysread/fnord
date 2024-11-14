defmodule AI.Tools.Planner do
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
    label = "Examining findings and planning the next steps"
    status_id = Ask.add_step(label)

    agent
    |> AI.Agent.Planner.new()
    |> AI.Agent.Planner.get_suggestion()
    |> then(fn
      {:ok, suggestion} ->
        Ask.finish_step(status_id, :ok)
        {:ok, "[planner_tool]\n#{suggestion}"}

      {:error, reason} ->
        Ask.finish_step(status_id, :error, label, reason)
        {:error, reason}
    end)
  end
end
