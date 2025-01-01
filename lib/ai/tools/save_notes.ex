defmodule AI.Tools.SaveNotes do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"notes" => notes}), do: {"Saving research", Enum.join(notes, "\n")}

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

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
              Format: `{topic <topic> {fact <fact>} {fact <fact>} ...}`
              ONE `topic` per note, with multiple `fact`s per topic.
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
    with {:ok, notes} <- Map.fetch(args, "notes"),
         :ok <- validate_notes(notes) do
      project = Store.get_project()
      notes |> Enum.each(&new_note(&1, project))
      :ok
    end
  end

  defp validate_notes(notes) do
    if Enum.all?(notes, &Store.Project.Note.is_valid_format?/1) do
      :ok
    else
      {:error, :invalid_format}
    end
  end

  defp new_note(text, project) do
    project
    |> Store.Project.Note.new()
    |> Store.Project.Note.write(text)
  end
end
