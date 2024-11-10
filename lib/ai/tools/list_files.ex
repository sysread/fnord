defmodule AI.Tools.ListFiles do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "list_files_tool",
        description: "list all files in the project database",
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
    Store.new(agent.opts.project)
    |> Store.list_files(true)
    |> Enum.join("\n")
    |> then(fn res -> {:ok, res} end)
  end
end
