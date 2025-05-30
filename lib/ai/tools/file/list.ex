defmodule AI.Tools.File.List do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(_args), do: "Listing files in project"

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    # -1 for the header, "[file_list_tool]"
    lines = count_lines(result) - 1
    "Found #{lines} files"
  end

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
        strict: true,
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
    with project <- Store.get_project(),
         {_project, file_stream} <- Store.Project.source_files(project) do
      file_stream
      |> Stream.map(& &1.rel_path)
      |> Enum.sort()
      |> Enum.join("\n")
      |> then(fn res -> {:ok, "[file_list_tool]\n#{res}"} end)
    end
  end

  defp count_lines(str) do
    for <<c <- str>>, c == ?\n, reduce: 1 do
      acc -> acc + 1
    end
  end
end
