defmodule AI.Tools.Planner do
  @behaviour AI.Tools

  @no_solution "I am still researching and do not yet have a proposed solution."

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
          properties: %{
            solution: %{
              type: "string",
              description: """
              Request that the planner review your proposed solution to the
              user's request. It will analyze the conversation and your
              solution, and then either respond affirmatively or suggest
              refinements.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    solution = get_solution(args)

    status_id =
      if solution == @no_solution do
        UI.add_status("Examining findings and planning the next steps")
      else
        UI.add_status("Reviewing proposed solution")
      end

    AI.Agent.Planner.new(agent, solution)
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

  defp get_solution(%{"solution" => solution}), do: solution
  defp get_solution(_), do: @no_solution
end
