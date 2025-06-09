defmodule AI.Agent.Default.Rollups do
  @behaviour AI.Agent

  @model AI.Model.fast()

  @prompt """
  You are given a sequence of JSONL-encoded messages representing a conversation.
  Each line is one JSON object.

  There are four types of lines:
  - User messages ({"role": "user", ...})
  - Assistant messages ({"role": "assistant", ...})
  - Tool messages ({"role": "tool", ...})
  - Timestamp markers ({"timestamp": "<ISO8601 string>"})

  Lines are in chronological order.
  Some lines may be timestamp markers.
  Timestamp markers are inserted into the conversation at irregular intervals, when it is determined that a new interaction has begun.
  Use the timestamp markers to to determine the boundaries of each month.

  Your task is to generate a summary for each calendar month covered in the input.
  For each month in which there is any activity (at least one message), output a summary of that month's conversation activity, focusing on the most important topics, actions, questions, and decisions.
  If there are recurring themes or changes over the month, note them.
  If a month only contains trivial or system/tool messages, note this in the summary.
  Be particularly careful to preserve solutions to problems, useful troubleshooting steps, significant decisions, user preferences, and important facts about the user or their projects.
  Do not generate summaries for months with no activity.

  Do not include messages, timestamps, or any other content in your output.
  Do not include summaries for months not present in the input.
  Do not attempt to deduplicate or merge months.
  Be concise, but preserve important context for future reference.

  Your output must be valid JSONL, one object per line, each in this format:
  ```
  {"type": "summary", "month": "YYYY-MM", "content": "<your summary>"}
  ```

  It is an error to include any explanation, preamble, or reasoning in your output.
  Respond ONLY with the JSONL summary lines, without any additional text or formatting.
  """

  @impl AI.Agent
  def get_response(_opts) do
    with {:ok, conversation_jsonl} <- get_conversation_history_jsonl(),
         {:ok, summaries} <- get_summaries(conversation_jsonl) do
      {:ok, summaries}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_summaries(conversation_jsonl, attempt \\ 1)

  defp get_summaries(_, attempt) when attempt > 3 do
    {:error, :max_attempts_reached}
  end

  defp get_summaries(conversation_jsonl, attempt) do
    AI.Completion.get(
      model: @model,
      prompt: @prompt,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(conversation_jsonl)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        msgs =
          response
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn line ->
            with {:ok, json} <- Jason.decode(line) do
              json
            else
              _ -> nil
            end
          end)

        # Verify whether the response contains valid JSONL summaries.
        # If the response is not valid JSONL, retry
        if Enum.any?(msgs, &is_nil/1) do
          get_summaries(conversation_jsonl, attempt + 1)
        else
          {:ok, msgs}
        end

      {:error, reason} ->
        UI.warn("AI model failed to generate conversation rollups: #{reason}")
        # If the AI model fails, retry up to 3 times
        get_summaries(conversation_jsonl, attempt + 1)
    end
  end

  defp get_conversation_history_jsonl do
    Store.DefaultProject.Conversation.read_file()
    # Reverse the stream to process in reverse chronological order
    |> Enum.reverse()
    # Drop messages until we get to the most recent timestamp marker
    |> Enum.drop_while(fn
      %{"timestamp" => _} -> false
      _ -> true
    end)
    # The list now contains everything up to (and including) the most recent
    # timestamp marker.
    |> Enum.reverse()
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
    |> case do
      "" -> {:error, :no_conversation_history}
      jsonl -> {:ok, jsonl}
    end
  end
end
