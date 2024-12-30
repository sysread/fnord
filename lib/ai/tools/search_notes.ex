defmodule AI.Tools.SearchNotes do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "search_notes_tool",
        description: """
        Performs a semantic search of notes you have previously saved about
        this project. Note that previously saved notes may be out of date. It
        is HIGHLY advised that you confirm anything remotely dubious with the
        file_info_tool.
        """,
        parameters: %{
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: "The text to search for in your notes."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, query} <- Map.fetch(args, "query") do
      project = Store.get_project()

      Store.Note.search(project, query)
      |> Enum.reduce([], fn {_score, note}, acc ->
        with {:ok, text} <- Store.Note.read_note(note) do
          [text | acc]
        end
      end)
      |> Enum.reverse()
      |> then(&{:ok, &1})
    end
  end
end
