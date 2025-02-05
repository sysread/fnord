defmodule AI.Tools.Notes.Save do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"topic" => topic, "facts" => facts}) do
    {"Saving research", format_note(topic, facts)}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(args) do
    with {:ok, topic} <- get_topic(args),
         {:ok, facts} <- get_facts(args) do
      {:ok, %{"topic" => topic, "facts" => facts}}
    end
  end

  defp get_topic(%{"topic" => topic}), do: {:ok, topic}
  defp get_topic(_args), do: AI.Tools.required_arg_error("topic")

  defp get_facts(%{"facts" => facts}), do: {:ok, facts}
  defp get_facts(_args), do: AI.Tools.required_arg_error("facts")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "notes_save_tool",
        description: """
        Saves research notes about the project that you have learned from your
        research efforts. These should be concise facts about the project or
        the domain in which it operates, inferences you have made from your
        research, or short guides to common operations within the project.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
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
  def call(_completion, args) do
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
