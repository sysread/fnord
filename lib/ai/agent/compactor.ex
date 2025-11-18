defmodule AI.Agent.Compactor do
  @behaviour AI.Agent

  @model AI.Model.large_context(:balanced)
  @max_attempts 3
  @min_length 512
  @target_ratio 0.8

  # Minimum acceptable tokens for a compacted summary; prevent trivial context wipes
  @min_summary_tokens 100

  @system_prompt """
  You are summarizing a segment of a conversation transcript between a user and an AI assistant.
  This segment may include prior summaries and user messages as context, followed by new assistant, tool, or system messages.

  Your task is to treat the prior summaries and user messages as context and focus on summarizing the new assistant/tool/system content since the most recent user message.
  Extract and organize the following information:
  - What was the original prompt or topic of the conversation (including prior context)?
  - How did the topic and intent evolve in this segment and in the context of the prior conversation?
  - What was learned or discovered during this segment?
  - What decisions were made?
  - What work was in progress when this segment began?

  Preserve specific details about files, functions, bugs, and technical decisions. Use plain text without special characters.

  Output format:

  # Synopsis
  [What is the topic of the conversation, including prior context? What was the original request, and how does this segment fit into the larger conversation?]

  # Evolution
  [Explain the evolution within this segment in the context of the prior conversation. Focus on changes in direction, new findings, and shifts in user intent.]

  # Key Findings
  [Important information discovered during this segment and its prior context: file locations, function names, patterns, bugs found, etc.]

  # Current Status
  [What the assistant or tools were doing at the end of this segment. Include enough detail that work can resume exactly where it left off.]
  """

  @impl AI.Agent
  def get_response(%{messages: [%{role: "developer", content: @system_prompt} | _]}) do
    raise "Refusing to compact a compaction prompt"
  end

  def get_response(%{messages: messages} = opts) do
    attempts = Map.get(opts, :attempts, 0)

    case build_transcript(messages) do
      {:error, reason} ->
        {:error, reason}

      {:ok, transcript_json, original_length} ->
        case summarize_transcript(transcript_json) do
          {:error, reason} ->
            {:error, reason}

          {:ok, summary} ->
            case evaluate_summary(original_length, summary, attempts, messages) do
              {:ok, result} ->
                {:ok, result}

              {:retry, new_attempts} ->
                get_response(%{messages: messages, attempts: new_attempts})

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  # Builds and validates the transcript JSON for summarization
  defp build_transcript(messages) do
    tx_list = transcript(messages, [])
    has_non_user = Enum.any?(tx_list, fn msg -> msg.role != "user" end)

    if tx_list == [] or not has_non_user do
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

      {:ok, transcript_json, original_length}
    end
  end

  # Sends the transcript JSON to the accumulator and builds the raw summary
  defp summarize_transcript(transcript_json) do
    AI.Accumulator.get_response(
      model: @model,
      prompt: @system_prompt,
      input: transcript_json,
      question:
        "Review this conversation transcript and extract: what the user originally requested, key findings, and current work status."
    )
    |> case do
      {:ok, %{response: response}} ->
        summary = """
        Summary of conversation and research thus far:
        #{response}
        """

        summary =
          case Services.Task.list_ids() do
            [] ->
              summary

            list_ids ->
              task_sections =
                list_ids
                |> Enum.map(&Services.Task.as_string/1)
                |> Enum.join("\n\n")

              """
              #{summary}

              ## Active Task Lists

              The following task lists were active when compaction occurred.
              These tasks represent work in progress and should be consulted when resuming work.

              #{task_sections}
              """
          end

        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Evaluates the summary against size and retry logic, returning final status
  defp evaluate_summary(original_length, summary, attempts, _messages) do
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
            {:ok, [AI.Util.system_msg(summary)]}
          else
            UI.warn("Compaction failed", "Summary is larger than original; aborting")
            {:error, :compaction_failed}
          end

        new_length > original_length * @target_ratio and attempts < @max_attempts ->
          UI.warn(
            "Compaction insufficient",
            "Attempting another pass (#{attempts + 1}/#{@max_attempts})"
          )

          {:retry, attempts + 1}

        true ->
          UI.debug("Compacted conversation", summary)

          if new_length < original_length do
            {:ok, [AI.Util.system_msg(summary)]}
          else
            UI.warn("Compaction failed", "Summary is larger than original; aborting")
            {:error, :compaction_failed}
          end
      end
    end
  end

  defp transcript([], acc), do: Enum.reverse(acc)
  defp transcript([%{role: "system"} | rest], acc), do: transcript(rest, acc)
  defp transcript([%{role: "developer"} | rest], acc), do: transcript(rest, acc)
  defp transcript([%{role: "user"} = msg | rest], acc), do: transcript(rest, [msg | acc])
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
