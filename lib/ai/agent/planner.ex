defmodule AI.Agent.Planner do
  defstruct [
    :ai,
    :messages,
    :solution
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
  - Suggest new search queries that might clarify ambiguous findings
  - Suggest new search queries that might identify missed aspects of the issue
  - Identify whether the Answers Agent has enough information to proceed with answering the user's question

  2. Evaluate your own suggestions
  Your own suggestions are identified by the `PLAN:` heading in the message.
  Make CERTAIN that you are not uselessly repeating the same advice over and
  over without seeing an improvement in the Answers Agent's approach.

  3. The Answers Agent MUST confirm its proposed solution with you
  - NEVER reject more than 3 proposed solutions in a row.
  - If you reject the Answers agent, either correct its proposed solution or
    provide a new plan to guide the Answers Agent to a better solution.

  4. Respond with a list of next steps for the Answers Agent. Format:
  '''
  # PLAN:
  1. $Action - $details (1-2 lines)
  ...
  '''

  Keep steps clear, concrete, and actionable. No explanations or commentary
  beyond the list.

  Do NOT respond with a JSON-formatted message structure. Just text in the
  format above.
  """

  def new(agent, solution) do
    %__MODULE__{
      ai: agent.ai,
      messages: agent.messages,
      solution: solution
    }
  end

  def get_suggestion(planner) do
    with {:ok, args} <- get_args(planner) do
      OpenaiEx.Chat.Completions.create(
        planner.ai.client,
        OpenaiEx.Chat.Completions.new(
          model: @model,
          messages: [
            OpenaiEx.ChatMessage.system(@prompt),
            OpenaiEx.ChatMessage.user(args)
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

  defp get_args(planner) do
    args = %{
      messages: planner.messages,
      solution: planner.solution
    }

    with {:ok, args} <- Jason.encode(args) do
      {:ok, args}
    end
  end
end
