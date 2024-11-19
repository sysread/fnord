defmodule AI.Tools.Outline do
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
    store = Store.new(agent.opts.project)

    with {:ok, file} <- Map.fetch(args, "file"),
         {:ok, data} <- Store.get_outline(store, file) do
      {:ok, data}
    end
  end
end
