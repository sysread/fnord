defmodule AI.Agent.Planner do
  defstruct [
    :ai,
    :messages
  ]

  @model "gpt-4o"

  @prompt """
  You are the Planner Agent, coordinating the work of the Answers Agent who
  interacts directly with users. You will receive conversation transcripts
  between users and the Answers Agent.

  Your task:
  1. Analyze the conversation to identify:
  - User's core goals
  - Current approach effectiveness
  - Any missed opportunities or wrong turns
  - Suggest new search queries that might clarify ambiguous findings
  - Suggest new search queries that might identify missed aspects of the issue
  - Identify whether the Answers Agent has enough information to proceed with answering the user's question

  2. Respond with a list of next steps for the Answers Agent. Format:
  '''
  # 1. $Action
  $details (1-2 lines)
  # 2. $action
  $details (1-2 lines)
  ...etc.
  '''

  Keep steps clear and actionable. No explanations or commentary beyond the
  list. Do NOT respond with a JSON-formatted message structure. Just text
  in the format above.
  """

  def new(agent) do
    %__MODULE__{
      ai: agent.ai,
      messages: agent.messages
    }
  end

  def get_suggestion(agent) do
    with {:ok, msgs_json} <- Jason.encode(agent.messages) do
      OpenaiEx.Chat.Completions.create(
        agent.ai.client,
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
