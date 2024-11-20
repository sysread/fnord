defmodule AI.Tools.Outline do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "outline_tool",
        description: "Retrieves an outline of symbols and calls in an indexed code file.",
        parameters: %{
          type: "object",
          required: ["file"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The absolute file path to the code file in the project. This
              parameter MUST be a **confirmed file** in the repository, as
              returned by the list_files_tool or the search_tool.
              """
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
