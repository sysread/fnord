defmodule AI.Tools.SearchNotes do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"query" => query}) do
    {"Searching prior research", query}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    notes =
      result
      |> Jason.decode!()
      |> Enum.join("\n")

    {"Found prior research", "\n#{notes}"}
  end

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
    |> Store.Project.notes()
    |> Enum.reduce([], fn note, acc ->
      with {:ok, text} <- Store.Project.Note.read_note(note) do
        [text | acc]
      else
        _ -> acc
      end
    end)
  end

  defp get_notes(project, query) do
    project
    |> Store.Project.search_notes(query)
    |> Enum.reduce([], fn {_score, note}, acc ->
      with {:ok, text} <- Store.Project.Note.read_note(note) do
        [text | acc]
      end
    end)
    |> Enum.reverse()
  end
end
