defmodule AI.Tools.ListFiles do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "list_files_tool",
        description: """
        Lists all files in the project database. You can discover quite a bit
        about a project by examining the layout of the repository.
        """,
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
    |> Store.list_files()
    |> Enum.join("\n")
    |> then(fn res -> {:ok, "[list_files_tool]\n#{res}"} end)
  end
end
