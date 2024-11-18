defmodule AI.Tools.GetOutline do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "outline_tool",
        description: "Retrieves an outline of symbols and calls in a code file.",
        parameters: %{
          type: "object",
          required: ["file"],
          properties: %{
            file: %{
              type: "string",
              description: "absolute file path to the code file in the project."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, file} <- Map.fetch(args, "file") do
      status_id = Tui.add_step("Retrieving symbolic map of", file)

      result =
        agent.opts.project
        |> Store.new()
        |> Store.get_outline(file)

      Tui.finish_step(status_id, :ok)

      result
    end
  end
end
