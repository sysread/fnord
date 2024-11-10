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
    Ask.update_status("Planning the next steps")

    AI.Agent.Planner.new(agent)
    |> AI.Agent.Planner.get_suggestion()
  end
end
