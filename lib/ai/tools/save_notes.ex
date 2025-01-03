defmodule AI.Tools.SaveNotes do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"notes" => notes}) do
    {"Saving research", inspect(notes)}
  end

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
        research efforts. These should be concise facts about the project or
        the domain in which it operates, inferences you have made from your
        research, or short guides to common operations within the project.
        """,
        parameters: %{
          type: "object",
          required: ["notes"],
          properties: %{
            notes: %{
              type: "array",
              description: """
              ONE `topic` per note, with multiple `fact`s per topic.
              Format: `{topic "<topic>" {fact "<fact>"} {fact "<fact>"} ...}`
              Failing to follow this format will result in an parsing error.
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
