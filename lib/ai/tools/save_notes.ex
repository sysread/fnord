defmodule AI.Tools.SaveNotes do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "save_notes_tool",
        description: """
        Saves short notes about the project that you have learned from your
        research efforts. These should be short, concise facts about the
        project or the domain in which it operates.
        """,
        parameters: %{
          type: "object",
          required: ["notes"],
          properties: %{
            notes: %{
              type: "array",
              description: """
              The text of each note to save. This should phrased such that it
              includes relevant context to understand the note. For example:
                - Wrong: "queries are stored in the Foo module"
                - Correct: "SQL queries are stored in the Foo module"
              """,
              items: %{
                type: "string"
              }
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, notes} <- Map.fetch(args, "notes") do
      project = Store.get_project()

      Enum.each(notes, fn note ->
        project
        |> Store.Note.new()
        |> Store.Note.write(note)
      end)

      {:ok, "Notes saved."}
    end
  end
end
