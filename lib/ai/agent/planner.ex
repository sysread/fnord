defmodule AI.Agent.Planner do
  defstruct [
    :ai,
    :messages
  ]

  @model "gpt-4o"

  @prompt """
  You are an AI agent within an application that provides a conversational
  interface to the user's project. Your job is to coordinate the work of the
  "Answers Agent", who directly answers the user's questions.

  In your role as the "Planner Agent", you will be provided with a script
  of the user's interactions with the "Answers Agent". Make a careful analysis
  of the conversation thus far. Think through the user's goals. Identify what
  steps the "Answers Agent" has taken to find the information in the project
  that the user is looking for. Determine whether their approach is effective
  or if there are better ways to achieve the user's goals.

  Based on your analysis, identify the next steps that the "Answers Agent"
  should take to help the user find the information they are looking for.
  Actively coach the "Answers Agent" to redirect their efforts if you believe
  they are struggling or if they appear to be on the wrong track.

  Then, respond ONLY with your suggestion to the "Answers Agent" on how to
  proceed in the conversation. Your response may be in markdown format, and
  should be addressed to the "Answers Agent".
  """

  def new(agent) do
    %__MODULE__{
      ai: agent.ai,
      messages: agent.messages
    }
  end

  def get_suggestion(planner) do
    with {:ok, msgs_json} <- Jason.encode(planner.messages) do
      OpenaiEx.Chat.Completions.create(
        planner.ai.client,
        OpenaiEx.Chat.Completions.new(
          model: @model,
          messages: [
            OpenaiEx.ChatMessage.system(@prompt),
            OpenaiEx.ChatMessage.user(msgs_json)
          ]
        )
      )
      |> case do
        {:ok, %{"choices" => [%{"message" => %{"content" => suggestion}}]}} ->
          {:ok, suggestion}

        {:error, reason} ->
          {:error, reason}

        response ->
          {:error, "unexpected response: #{inspect(response)}"}
      end
    end
  end
end
