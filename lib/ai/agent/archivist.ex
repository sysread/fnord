defmodule AI.Agent.Archivist do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  You are the Archivist Agent.
  You are responsible for reading, organizing, assimilating, and managing prior research.
  You will be provided with a query from the Planner Agent or the Answers Agent LLMs.
  Use your tools to search through the existing research and respond will ALL relevant information.

  #{AI.Util.agent_to_agent_prompt()}
  """

  @tools [
    AI.Tools.SearchNotes.spec()
  ]

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, query} <- Map.fetch(opts, :query),
         {:ok, %{response: response}} <- build_response(ai, query) do
      {:ok, response}
    end
  end

  defp build_response(ai, query) do
    AI.Completion.get(ai,
      max_tokens: @max_tokens,
      model: @model,
      tools: @tools,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(query)
      ]
    )
  end
end
