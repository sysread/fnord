defmodule AI.Agent.SagaScribe do
  @moduledoc """
  An AI.Agent that summarizes chat history in a friendly, concise, and engaging style,
  producing a coherent and user-friendly summary.
  """

  @model AI.Model.balanced()

  @prompt """
  You are the Conversation Agent, an AI agent within a larger, coordinated system.
  Your role is to document conversations, converting an OpenAI-style completion transcript into meeting minutes.

  You MUST document:
    - **User messages must be captured EXACTLY word-for-word as a direct quote**
    - AI responses (summarized, capturing significant points)
    - Decision-making logic
    - Debate and discussion points

  Do not include any system messages, as these are not part of the conversation.

  The overriding goal is to write clear, concise minutes that capture the direction of the conversation, as well as research (in the form of tool_call messages and responses).
  Your notes will form the basis of any future follow-up discussion, so it is essential that you capture the important details accurately, so that the Coordinating Agent is able to respond sensibly to the user, without appearing to have forgotten important details or decisions made.
  The next time the user responds to the conversation, the Coordinating Agent will only see your notes in place of the original conversation transcript.

  Respond ONLY with the summary of the conversation, formatted as meeting minutes.
  Do not include any additional text, summary, introduction, or explanations.
  """

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(args) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601()

    with {:ok, messages} <- Map.fetch(args, :messages),
         previous_summary <- Map.get(args, :previous_summary, ""),
         {:ok, minutes} <- get_minutes(messages, previous_summary) do
      {:ok, build_new_summary(timestamp, minutes, previous_summary)}
    end
  end

  defp build_new_summary(timestamp, minutes, "") do
    """
    # Conversation Minutes #{timestamp}
    #{minutes}
    """
  end

  defp build_new_summary(timestamp, minutes, previous_summary) do
    """
    #{previous_summary}

    # Conversation Minutes #{timestamp}
    #{minutes}
    """
  end

  defp get_minutes(messages, "") do
    transcript = build_transcript(messages)

    prompt = """
    # Conversation Transcript
    This is the conversation transcript you are summarizing.
    ```jsonl
    #{transcript}
    ```
    """

    get_completion(prompt)
  end

  defp get_minutes(messages, previous_summary) do
    transcript = build_transcript(messages)

    prompt = """
    # Previous Notes
    These are the notes you recorded last time for this conversation.
    They are included for reference, but you should not repeat them in your response.
    Your new notes will be appended directly to these notes, so you should not repeat any of this section in your response.
    -----
    #{previous_summary}

    # Conversation Transcript
    This is the conversation transcript you are summarizing.
    ```jsonl
    #{transcript}
    ```
    """

    get_completion(prompt)
  end

  defp get_completion(input) do
    AI.Completion.get(
      model: @model,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(input)
      ]
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_transcript(messages) do
    messages
    |> Enum.filter(fn
      %{role: "system"} ->
        false

      %{role: "developer"} ->
        false

      %{role: "assistant", content: msg} when is_binary(msg) ->
        !String.starts_with?(msg, "<think>")

      _ ->
        true
    end)
    |> Enum.map(fn msg -> Jason.encode!(msg) end)
    |> Enum.join("\n")
  end
end
