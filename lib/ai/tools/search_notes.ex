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

        If no query is provided, ALL notes will be returned.
        """,
        parameters: %{
          type: "object",
          required: [],
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
    query = Map.get(args, "query", nil)
    project = Store.get_project()

    project
    |> get_notes(query)
    |> then(&{:ok, &1})
  end

  defp get_notes(project, nil) do
    project
    |> Store.Note.list_notes()
    |> Enum.map(&Store.Note.read_note/1)
  end

  defp get_notes(project, query) do
    project
    |> Store.Note.search(query)
    |> Enum.reduce([], fn {_score, note}, acc ->
      with {:ok, text} <- Store.Note.read_note(note) do
        [text | acc]
      end
    end)
    |> Enum.reverse()
  end
end
