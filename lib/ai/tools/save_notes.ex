defmodule AI.Tools.SaveNotes do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"topic" => topic, "facts" => facts}) do
    {"Saving research", format_note(topic, facts)}
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
        Saves research notes about the project that you have learned from your
        research efforts. These should be concise facts about the project or
        the domain in which it operates, inferences you have made from your
        research, or short guides to common operations within the project.
        """,
        parameters: %{
          type: "object",
          required: ["topic", "facts"],
          properties: %{
            topic: %{
              type: "string",
              description: "The topic of the notes."
            },
            facts: %{
              type: "array",
              description: "An array of strings, each representing one fact about the topic.",
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
    with {:ok, topic} <- Map.fetch(args, "topic"),
         {:ok, facts} <- Map.fetch(args, "facts") do
      note = format_note(topic, facts)

      Store.get_project()
      |> Store.Project.Note.new()
      |> Store.Project.Note.write(note)

      :ok
    end
  end

  defp format_note(topic, facts) do
    facts =
      facts
      |> Enum.map(&"{fact \"#{&1}\"}")
      |> Enum.join(" ")

    "{topic \"#{topic}\" #{facts}}"
  end
end
