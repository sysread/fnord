defmodule AI.Agent.Planner do
  defstruct [
    :ai,
    :messages
  ]

  @model "gpt-4o"

  @prompt """
  You are the Planner Agent, coordinating the work of the Answers Agent who
  interacts directly with users. The Answers Agent uses the planner_tool to
  request your assistance in analyzing its research and suggesting next steps.

  You will receive conversation transcripts between users and the Answers
  Agent.

  1. Your task is to analyze the Answer Agent's research to identify:
  - User's core goals
  - Current approach effectiveness
  - Any missed opportunities or wrong turns
  - Suggest new search queries that might clarify ambiguous findings or identify missed aspects of the issue
  - Identify whether the Answers Agent has enough information to proceed with answering the user's question

  For example, if the user is asking HOW to do something that already exists in
  the code base, guide the Answers Agent toward finding examples of it. If the
  user wants to change the behavior of something, ensure the Answers Agent is
  considering upstream and downstream changes that might be required as a
  consequence.

  2. Evaluate your own suggestions
  Your own suggestions are identified by the `PLAN:` heading in the message.
  Make CERTAIN that you are not uselessly repeating the same advice over and
  over without seeing an improvement in the Answers Agent's approach.

  3. Respond with a list of next steps for the Answers Agent. Format:
  '''
  # PLAN:
  1. $Action - $details (1-2 lines)
  2. $Action - $details (1-2 lines)
  ...etc.
  '''

  Keep steps clear, concrete, and actionable. No explanations or commentary
  beyond the list.

  Do NOT respond with a JSON-formatted message structure. Just text in the
  format above.
  """

  def new(agent) do
    %__MODULE__{
      ai: agent.ai,
      messages: agent.messages
    }
  end

  def get_suggestion(planner) do
    with {:ok, msg_json} <- Jason.encode(planner.messages) do
      OpenaiEx.Chat.Completions.create(
        planner.ai.client,
        OpenaiEx.Chat.Completions.new(
          model: @model,
          messages: [
            OpenaiEx.ChatMessage.system(@prompt),
            OpenaiEx.ChatMessage.user(msg_json)
          ]
        )
      )
      |> case do
        {:ok, %{"choices" => [%{"message" => %{"content" => suggestion}}]}} -> {:ok, suggestion}
        {:error, reason} -> {:error, reason}
        response -> {:error, "unexpected response: #{inspect(response)}"}
      end
    end
  end
end
