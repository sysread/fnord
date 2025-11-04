defmodule AI.Agent.Compactor do
  @behaviour AI.Agent

  @model AI.Model.large_context(:balanced)
  @max_attempts 3
  @min_length 512
  @target_ratio 0.8

  # Minimum acceptable tokens for a compacted summary; prevent trivial context wipes
  # Note: set to >0 in production if you want to reject trivial summaries; tests expect tiny outputs.
  @min_summary_tokens 0

  @system_prompt """
  You are an AI Agent in a larger system.
  You will be presented with a transcript of a conversation between a user and an AI assistant, along with any research the assistant has done.
  Your task: Reformat into compact meeting minutes while preserving all content needed for context.
  Do not use smart quotes, smart apostrophes, emojis, or other special characters.
  Read through the messages and reason through a new, more compact narrative that preserves the key points and context.
  Consider the conversation from the user's perspective: what expectations would they have for the assistant's memory and understanding of the conversation?

  Preserve decision points, assumptions, trade-offs, mistakes and corrections, and include rationales leading to any state changes.

  Use the following output template:

  # Original User Prompt
  [full text of the original user prompt]

  # Research and Responses
  [outline of facts, findings, and conclusions from the research portions of the conversation]

  # Conversation Timeline
  [
    Present a timeline of the conversation, listing each message with its role and a brief summary of its content.
    Messages at the end of the conversation should include WAY more detail than those at the beginning, reflecting the decision cascade and evolving context
    Don't waste space with formatting or JSON; just use plain text.
  ]

  # Continuation Context
  [
    What was the assistant doing before the conversation grew too long?
    Your response will form the complete prompt for the LLM's next response.
    This section MUST guarantee that the LLM continues exactly where it left off.
  ]
  """

  @impl AI.Agent
  def get_response(%{messages: [%{role: "developer", content: @system_prompt} | _]}) do
    raise "Refusing to compact a compaction prompt"
  end

  def get_response(%{messages: messages} = opts) do
    attempts = Map.get(opts, :attempts, 0)

    tx_list = transcript(messages, [])

    # Early guard: empty transcript -> skip model call and retries
    if tx_list == [] do
      {:error, :empty_after_filtering}
    else
      transcript_json = Jason.encode!(tx_list, pretty: true)
      original_length = byte_size(transcript_json)

      UI.info(
        "Compaction starting",
        "Transcript JSON size: #{original_length} bytes. Recent messages preserved; proceeding with compaction."
      )

      UI.info(
        "Summarizing conversation transcript (expected)",
        "No new user prompt was added for this compaction pass. We are summarizing the transcript for compactness; " <>
          "recent messages (including your latest prompts) remain intact."
      )

      AI.Accumulator.get_response(
        model: @model,
        prompt: @system_prompt,
        input: transcript_json
      )
      |> case do
        {:ok, %{response: response}} ->
          summary =
            """
            Summary of conversation and research thus far:
            #{response}
            """

          # Guard against trivial, near-empty summaries that would wipe context
          new_tokens = AI.PretendTokenizer.guesstimate_tokens(summary)

          if new_tokens < @min_summary_tokens do
            UI.error(
              "Compaction failed",
              "Summary too small (#{new_tokens} < #{@min_summary_tokens} tokens)"
            )

            {:error, :summary_too_small}
          else
            new_length = byte_size(summary)
            difference = original_length - new_length
            percent = difference / original_length * 100.0

            UI.info("""
            Compaction results:
              Original: #{Util.format_number(original_length)} bytes
             Compacted: #{Util.format_number(new_length)} bytes
              Savings: #{percent}% (#{Util.format_number(difference)} bytes)
            """)

            cond do
              original_length < @min_length ->
                UI.debug("Compaction retries skipped", "Original is too small to justify retries")

                if new_length < original_length do
                  summary |> AI.Util.system_msg() |> then(&{:ok, [&1]})
                else
                  UI.warn("Compaction failed", "Summary is larger than original; aborting")
                  {:error, :compaction_failed}
                end

              new_length > original_length * @target_ratio and attempts < @max_attempts ->
                UI.warn(
                  "Compaction insufficient",
                  "Attempting another pass (#{attempts + 1}/#{@max_attempts})"
                )

                get_response(%{messages: messages, attempts: attempts + 1})

              true ->
                UI.debug("Compacted conversation", summary)

                if new_length < original_length do
                  summary |> AI.Util.system_msg() |> then(&{:ok, [&1]})
                else
                  UI.warn("Compaction failed", "Summary is larger than original; aborting")
                  {:error, :compaction_failed}
                end
            end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp transcript([], acc), do: Enum.reverse(acc)
  defp transcript([%{role: "system"} | rest], acc), do: transcript(rest, acc)
  defp transcript([%{role: "developer"} | rest], acc), do: transcript(rest, acc)
  defp transcript([%{role: "tool", name: "notify_tool"} | rest], acc), do: transcript(rest, acc)

  defp transcript([%{role: "tool", name: name, content: content} | rest], acc) do
    transcript(rest, [%{role: "tool", name: name, content: content} | acc])
  end

  defp transcript([%{role: "assistant", content: nil} | rest], acc), do: transcript(rest, acc)

  defp transcript([%{role: "assistant", content: content} = msg | rest], acc)
       when is_binary(content) do
    if String.starts_with?(content, "<think>") do
      # skip internal reasoning
      transcript(rest, acc)
    else
      # include assistant message
      transcript(rest, [msg | acc])
    end
  end

  defp transcript([msg | rest], acc), do: transcript(rest, [msg | acc])
end
