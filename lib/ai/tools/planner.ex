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
    status_id = UI.add_status("Examining findings and planning the next steps")

    AI.Agent.Planner.new(agent)
    |> AI.Agent.Planner.get_suggestion()
    |> case do
      {:ok, suggestion} ->
        UI.complete_status(status_id, :ok)
        {:ok, suggestion}

      {:error, reason} ->
        UI.complete_status(status_id, :error, reason)
        {:error, reason}
    end
  end
end
