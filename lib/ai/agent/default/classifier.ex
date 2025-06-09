defmodule AI.Agent.Default.Classifier do
  @behaviour AI.Agent

  @model AI.Model.fast()

  @prompt """
  Your role is to classify a user prompt as either:
    1. Continuing the existing conversation
    2. Beginning a new conversation

  Although the conversation is asynchronous, please take into account the
  amount of time that has elapsed since the last message. If you are waffling,
  use that to help you decide.

  If the user's prompt is likely continuing the previous topic of conversation,
  respond ONLY with "continue". If you believe the user's prompt is a
  significant change in topic or context, respond ONLY with "new".

  If the new message includes an obvious greeting or introduction to a new
  topic, it is likely a new conversation. If the user is asking a follow-up
  question or otherwise logically continuing the existing conversation, it is
  likely a continuation.

  It is an error to respond with ANYTHING other than "continue" or "new",
  excluding the quotation marks. Do not include any explanation, preamble, or
  additional text.
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, user_prompt} <- Map.fetch(opts, :user_prompt),
         {:ok, ts} <- Map.fetch(opts, :timestamp),
         {:ok, messages} <- Map.fetch(opts, :messages) do
      classify(user_prompt, ts, messages)
    end
  end

  # ----------------------------------------------------------------------------
  # Requests that the LLM review the most recent assistant and user messages in
  # the conversation and determine if the conversation should be considered
  # "new" or "continued". A conversation is considered "new" if the user's
  # message is a marked change in topic from the most recent messages.
  # ----------------------------------------------------------------------------
  defp classify(_, _, []), do: {:ok, true}

  defp classify(user_msg, ts, messages) do
    messages
    |> group_interactions()
    |> Enum.take(-3)
    |> Jason.encode()
    |> case do
      {:ok, transcript} -> classify_transcript(user_msg, ts, transcript)
      other -> other
    end
  end

  defp group_interactions(messages), do: group_interactions([], messages)

  defp group_interactions(acc, []), do: Enum.reverse(acc)

  defp group_interactions(acc, [%{"role" => "user"} = msg | rest]) do
    group_interactions([[msg] | acc], rest)
  end

  defp group_interactions([current | acc], [msg | rest]) do
    group_interactions([[msg | current] | acc], rest)
  end

  defp classify_transcript(user_msg, ts, transcript, attempt \\ 1) do
    seconds_since_last_msg =
      case DateTime.from_iso8601(ts) do
        {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt, :second)
        _ -> 0
      end

    # Regroup seconds_since_last_msg into the most appropriate unit
    time_since_last_msg =
      cond do
        seconds_since_last_msg < 60 -> "#{seconds_since_last_msg} second(s)"
        seconds_since_last_msg < 3600 -> "#{div(seconds_since_last_msg, 60)} minute(s)"
        seconds_since_last_msg < 86400 -> "#{div(seconds_since_last_msg, 3600)} hour(s)"
        true -> "#{div(seconds_since_last_msg, 86400)} day(s)"
      end

    AI.Completion.get(
      model: @model,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg("""
        # Previous conversation messages:
        #{transcript}

        # User's new message:
        #{user_msg}

        It has been #{time_since_last_msg} since the most recent response.
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        response
        |> String.trim()
        |> String.downcase()
        |> case do
          "continue" -> {:ok, :continue}
          "new" -> {:ok, :new}
          _ when attempt < 3 -> classify_transcript(user_msg, transcript, ts, attempt + 1)
          _ -> {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
