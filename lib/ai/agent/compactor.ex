defmodule AI.Agent.Compactor do
  @behaviour AI.Agent

  @model AI.Model.large_context()

  @system_prompt """
  You are a conversation summarization assistant. Given a sequence of chat
  messages, compress the conversation into a concise summary that retains key
  details, decisions, and context necessary for future interactions. Preserve
  speaker attributions and important facts, remove redundancy, and format the
  output as a list of messages compatible with the original schema. Respond
  ONLY with the text summary, without any additional commentary or
  explanations.
  """

  @impl AI.Agent
  def get_response(%{messages: [%{role: "developer", content: @system_prompt} | _]}) do
    raise "Refusing to compact a compaction prompt"
  end

  def get_response(%{messages: messages}) do
    transcript = AI.Util.research_transcript(messages)

    AI.Completion.get(
      model: @model,
      messages: [
        AI.Util.system_msg(@system_prompt),
        AI.Util.user_msg(transcript)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        """
        This is a compacted summary of the conversation you have been having
        with the user. It is designed to help you retain important context
        and decisions without overwhelming your context window with excessive
        detail.

        ## Summary
        #{response}
        """
        |> AI.Util.system_msg()
        |> then(&{:ok, [&1]})

      {:error, %{response: response}} ->
        {:error, response}
    end
  end
end
