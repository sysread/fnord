defmodule AI.Tools.Notes do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "prior_research",
        description: """
        Extracts information from prior research notes, collected during previous interactions with the user.
        This is your FIRST point of reference for any information you need to answer the user's question.
        """,
        parameters: %{
          type: "object",
          required: ["question"],
          properties: %{
            question: %{
              type: "string",
              description: "The information you wish to extract from the prior research notes"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"question" => question}) do
    {"Requesting prior research", question}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    {"Prior research identified", result}
  end

  @impl AI.Tools
  def call(%{"question" => question}) do
    {:ok, Services.Notes.ask(question)}
  end
end
