defmodule AI.Tools.File.List do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: AI.Tools.has_indexed_project()

  @impl AI.Tools
  def ui_note_on_request(_args), do: "Listing files in project"

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_list_tool",
        description: """
        Lists all files in the project database. You can discover quite a bit
        about a project by examining the layout of the repository.
        """,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: [],
          properties: %{}
        }
      }
    }
  end

  @impl AI.Tools
  def call(_args) do
    with {:ok, project} <- Store.get_project(),
         {_project, file_stream} <- Store.Project.source_files(project) do
      file_stream
      |> Stream.map(& &1.rel_path)
      |> Enum.sort()
      |> Enum.join("\n")
      |> then(fn res -> {:ok, "[file_list_tool]\n#{res}"} end)
    end
  end
end
