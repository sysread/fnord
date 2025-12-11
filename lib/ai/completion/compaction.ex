defmodule AI.Completion.Compaction do
  @min_savings_tersified 0.5

  @spec compact(AI.Util.msg_list()) :: {:ok, AI.Util.msg_list(), non_neg_integer}
  def compact(msgs) do
    original_usage =
      msgs
      |> Jason.encode!()
      |> AI.PretendTokenizer.guesstimate_tokens()

    UI.report_step("[compaction]", "Compacting conversation (~#{original_usage} tokens)")

    with {:ok, tersified_msgs} <- tersified(msgs) do
      new_usage =
        tersified_msgs
        |> Jason.encode!()
        |> AI.PretendTokenizer.guesstimate_tokens()

      savings = Float.round((original_usage - new_usage) / original_usage * 100, 2)
      UI.report_step("[compaction]", "Savings: #{savings}%")

      {:ok, tersified_msgs, new_usage}
    else
      {:error, reason} ->
        UI.warn("[compaction]", "Failed: #{inspect(reason, pretty: true, limit: :infinity)}")
        {:ok, msgs, original_usage}
    end
  end

  defp tersified(msgs) do
    UI.report_step("[compaction]", "Compacting individual messages")

    with {:ok, tersified_msgs} <- tersify(msgs) do
      original_usage =
        msgs
        |> Jason.encode!()
        |> AI.PretendTokenizer.guesstimate_tokens()

      new_usage =
        tersified_msgs
        |> Jason.encode!()
        |> AI.PretendTokenizer.guesstimate_tokens()

      savings = (original_usage - new_usage) / original_usage

      if savings >= @min_savings_tersified do
        {:ok, tersified_msgs}
      else
        pct = Float.round(savings * 100, 2)
        UI.report_step("[compaction]", "Savings: #{pct}% - meh, let's try summarizing it")
        summarized(tersified_msgs)
      end
    end
  end

  defp summarized(msgs) do
    UI.report_step("[compaction]", "Summarizing conversation")

    with {:ok, summarized_msgs} <- summarize(msgs) do
      {:ok, summarized_msgs}
    end
  end

  # ----------------------------------------------------------------------------
  # Tersification: condenses messages individually. Only those messages up to
  # (but not including) the most recent user message are compacted.
  # ----------------------------------------------------------------------------
  @tersify_model AI.Model.fast()

  @tersify_prompt """
  You are an AI agent that compacts messages by restating them as tersely as possible without losing any information.
  The message below is part of a conversation between the user and an AI assistant.
  Drop filler. Use short words. Abbrev where possible. Skip mb chars unless critical.
  Keep just enough to preserve context. It's an LLM, so it will hallucinate to fill in the gaps.
  If there are numbered items or bullets, keep them (the user may have referenced them by number later, and we don't want to break that), but shorten them as much as possible.
  You must respond ONLY with the compacted message content, reduced in length as much as possible while preserving original meaning.
  Do not include ANY additional commentary or explanation.
  Your response most ONLY be the compacted message in the same voice as the original.
  """

  defp tersify(msgs) do
    # Split messages into two groups:
    # 1. Messages to retain as-is: from the most recent user message onward
    # 2. Messages to compact: all messages before the most recent user message
    {to_compact, to_retain} =
      msgs
      |> Enum.reverse()
      |> Enum.find_index(fn
        %{role: "user"} -> true
        _ -> false
      end)
      # Note that this step extracts from the original msgs, not the reversed one
      |> then(fn
        nil -> {[], msgs}
        idx -> Enum.split(msgs, length(msgs) - idx - 1)
      end)

    UI.progress_bar_start(:tersifier, "Squeezing *really* hard", length(to_compact))

    with {:ok, tersified} <- tersify_msgs(to_compact) do
      {:ok, tersified ++ to_retain}
    end
  end

  defp tersify_msgs(msgs) do
    msgs
    |> Util.async_stream(fn msg ->
      result = tersify_msg(msg)
      UI.progress_bar_update(:tersifier)
      result
    end)
    |> Enum.reduce_while([], fn
      {:ok, {:ok, msg}}, acc -> {:cont, [msg | acc]}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, {:timeout, _}}, _acc -> {:halt, {:error, :timeout}}
      {:exit, reason}, _acc -> {:halt, {:error, reason}}
      {:throw, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      msgs -> {:ok, Enum.reverse(msgs)}
    end
  end

  defp tersify_msg(%{content: nil} = msg), do: {:ok, msg}

  defp tersify_msg(%{content: content} = msg) do
    # Do not tersify previously generated summaries
    if is_summary_msg?(msg) do
      {:ok, msg}
    else
      is_thought? = has_think_tags?(msg)

      AI.Completion.get(
        model: @tersify_model,
        replay_conversation: false,
        compact?: false,
        messages: [
          AI.Util.system_msg(@tersify_prompt),
          AI.Util.user_msg(content)
        ]
      )
      |> case do
        {:ok, %{response: response}} ->
          content = String.trim(response)

          content =
            if is_thought? do
              "<think>#{content}</think>"
            else
              content
            end

          {:ok, %{msg | content: content}}

        {:error, reason} ->
          UI.warn("[compaction]", """
          Error compacting message:

          # Original Message:
          #{inspect(msg, pretty: true, limit: :infinity)}

          # Reason:
          #{inspect(reason, pretty: true, limit: :infinity)}
          """)

          {:ok, msg}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Summarization: takes the entire message transcript and summarizes it into a
  # single message.
  # ----------------------------------------------------------------------------
  @summarize_model AI.Model.fast()

  @summarize_prompt """
  You are an AI agent to compacts a conversation between the user and an AI assistant into *proper* meeting minutes.
  Your audience is the LLM itself, which will use these minutes to restore context for the next completion.
  It is important to preserve context in a way that will allow the AI assistant to perform it's next completion accurately, without any break in continuity.
  Build a compressed script of the conversation that captures the linear flow of ideas, instructions, and responses.
  It is essential that the LLM's context is restored with the complete cascade of information, but in as few tokens as possible.
  Retain as much detail as possible from user messages.
  Condense tool call results as much as possible while preserving all facts discovered.
  Compress assistant "thought" messages very aggressively.
  Compress assistant responses to the user moderately, focusing on preserving key information and facts rather than social niceties.
  A successful response can be read as-is to understand the complete conversation, with enough context for the LLM to recognize the evolution of the discussion.
  Respond ONLY with the compact transcript, without any additional commentary or explanation.
  """

  @summarizer_task """
  Provide a highly compacted transcription of the conversation, ensuring all critical information is preserved for context restoration.
  Consider how someone reading your summary would need to understand the flow of the conversation.
  Be aware of flows that might cause the LLM to lose context or hallucinate, since they will ONLY have your summary as their entire context.
  Do not omit anything that might harm the user's experience or the relevance of the LLM's next completion.
  """

  defp summarize(msgs) do
    UI.spin("Summarizing conversation", fn ->
      transcript = AI.Util.research_transcript(msgs)

      result =
        AI.Accumulator.get_response(
          model: @summarize_model,
          prompt: @summarize_prompt,
          question: @summarizer_task,
          input: transcript
        )
        |> case do
          {:ok, %{response: response}} ->
            {:ok,
             [
               AI.Util.user_msg("""
               <fnord-meta:summary />
               Summary of previous conversation:

               #{response}

               -----

               We were having the discussion outlined above.
               Please continue responding based on that context.
               """)
             ]}

          {:error, reason} ->
            {:error, reason}
        end

      {"Conversation summarized", result}
    end)
  end

  # ----------------------------------------------------------------------------
  # Utilities
  # ----------------------------------------------------------------------------
  defp has_think_tags?(%{content: content}) when is_binary(content) do
    content
    |> String.trim()
    |> String.downcase()
    |> String.starts_with?("<think>")
  end

  defp has_think_tags?(_), do: false

  defp is_summary_msg?(%{content: content}) when is_binary(content) do
    content
    |> String.trim()
    |> String.starts_with?("<fnord-meta:summary />")
  end

  defp is_summary_msg?(_), do: false
end
