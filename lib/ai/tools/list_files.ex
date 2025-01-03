defmodule AI.Tools.ListFiles do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(_args), do: "Listing files in project"

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

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
  def call(_agent, _args) do
    Store.get_project()
    |> Store.Project.stored_files()
    |> Stream.map(& &1.rel_path)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(fn res -> {:ok, "[list_files_tool]\n#{res}"} end)
  end
end
