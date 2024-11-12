defmodule AI.Agent.Defrag do
  defstruct [
    :ai,
    :messages
  ]

  @model "gpt-4o"

  @prompt """
  You are the Defrag Agent. You will be handed a JSON-formatted transcript of a
  conversation. Combine all of the tool_call request messages, tool_call
  response messages, as well as your own earlier summaries (identified by the
  presence of `# CONSOLIDATED FINDINGS` in the message contents) into a single
  message that efficiently consolidates all of the facts and decisions made
  thus far.

  - DO NOT modify the user's messages
  - DO retain files identified and information discovered about each of them
  - DO include discoveries about which files were unrelated
  - DO include all facts discovered within the conversation
  - DO include all of the information you have previously summarized
    (identified by the presence of `# CONSOLIDATED FINDINGS` in the message
    contents)

  Respond with your markdown-formatted message, prefixed with `# CONSOLIDATED FINDINGS`.
  """

  def msgs_to_defrag(agent) do
    agent.messages
    |> Enum.count(fn
      %{role: "assistant", tool_calls: _} ->
        false

      %{role: "tool"} ->
        false

      %{role: "assistant", content: content} ->
        String.match?(content, ~r/^# CONSOLIDATED FINDINGS/)

      _ ->
        true
    end)
  end

  def summarize_findings(agent) do
    defrag = %__MODULE__{ai: agent.ai, messages: agent.messages}

    with {:ok, msg_json} <- Jason.encode(defrag.messages) do
      OpenaiEx.Chat.Completions.create(
        defrag.ai.client,
        OpenaiEx.Chat.Completions.new(
          model: @model,
          messages: [
            OpenaiEx.ChatMessage.system(@prompt),
            OpenaiEx.ChatMessage.user(msg_json)
          ]
        )
      )
      |> case do
        {:ok, %{"choices" => [%{"message" => %{"content" => summary}}]}} ->
          {:ok, defragmented_msg_list(defrag, summary)}

        {:error, reason} ->
          {:error, reason}

        response ->
          {:error, "unexpected response: #{inspect(response)}"}
      end
    end
  end

  defp defragmented_msg_list(defrag, summary) do
    messages =
      defrag.messages
      |> Enum.filter(fn
        %{role: "assistant", tool_calls: _} ->
          false

        %{role: "tool"} ->
          false

        %{role: "assistant", content: content} ->
          String.match?(content, ~r/^# CONSOLIDATED FINDINGS/)

        _ ->
          true
      end)

    messages ++ [AI.Util.assistant_msg(summary)]
  end
end
