defmodule AI.Completion.Compaction do
  @moduledoc """
  Compaction utilities for AI.Completion.

  - Partial compaction: summarize only older history while preserving the last K
    assistant completion rounds (including their tool-call messages).
  - Full compaction: summarize the entire message list.

  Notes:
  - Helpers are private and documented with inline comments to avoid warnings for
    private @doc under warnings-as-errors.
  - No aliasing; callers should use full module names.
  """

  @compact_keep_rounds 2
  @compact_target_pct 0.8

  # True when the message is an assistant completion (binary content) and not an
  # internal `<think>` message.
  defp assistant_completion_msg?(%{role: "assistant", content: content})
       when is_binary(content) do
    not String.starts_with?(content, "<think>")
  end

  defp assistant_completion_msg?(_), do: false

  # True when the message is an assistant tool-call request (content nil with a
  # `tool_calls` list). If you require non-empty, enforce it at the call site.
  defp assistant_tool_request_msg?(%{role: "assistant", content: nil, tool_calls: calls})
       when is_list(calls) do
    true
  end

  defp assistant_tool_request_msg?(_), do: false

  # True when the message is a tool response (role `tool` with a `tool_call_id`).
  defp tool_response_msg?(%{role: "tool", tool_call_id: id}) when is_binary(id), do: true
  defp tool_response_msg?(_), do: false

  # Given an assistant completion index, include any immediately preceding tool
  # messages (assistant tool-call requests and tool responses) as part of the same
  # round, returning the start index for that round.
  defp round_start_for_completion(msgs, comp_idx) do
    j0 = comp_idx - 1

    j =
      Stream.iterate(j0, &(&1 - 1))
      |> Stream.take_while(&(&1 >= 0))
      |> Enum.reduce_while(j0, fn idx, _acc ->
        msg = Enum.at(msgs, idx)

        cond do
          tool_response_msg?(msg) -> {:cont, idx - 1}
          assistant_tool_request_msg?(msg) -> {:cont, idx - 1}
          true -> {:halt, idx}
        end
      end)

    j + 1
  end

  # Build a map of `tool_call_id -> {min_index, max_index}` to identify spans of
  # tool-call request/response pairs across the message list.
  defp build_tool_call_spans(msgs) do
    msgs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {msg, idx}, acc ->
      cond do
        assistant_tool_request_msg?(msg) ->
          Enum.reduce(msg.tool_calls, acc, fn %{id: id}, acc2 ->
            case Map.get(acc2, id) do
              nil -> Map.put(acc2, id, {idx, nil})
              {min_i, max_i} -> Map.put(acc2, id, {min(min_i, idx), max_i})
            end
          end)

        tool_response_msg?(msg) ->
          id = msg.tool_call_id

          case Map.get(acc, id) do
            nil -> Map.put(acc, id, {idx, idx})
            {min_i, max_i} -> Map.put(acc, id, {min_i || idx, max(max_i || idx, idx)})
          end

        true ->
          acc
      end
    end)
  end

  # Move the split backward if any tool-call span straddles it or if there is an
  # in-flight tool request before the split, ensuring round integrity.
  defp fixup_split_for_tool_straddles(split, spans) do
    straddlers =
      spans
      |> Enum.filter(fn {_id, {min_i, max_i}} ->
        not is_nil(min_i) and not is_nil(max_i) and min_i < split and max_i >= split
      end)

    inflight_before_split =
      spans
      |> Enum.filter(fn {_id, {min_i, max_i}} ->
        not is_nil(min_i) and is_nil(max_i) and min_i < split
      end)

    case {straddlers, inflight_before_split} do
      {[], []} ->
        split

      {some, other} ->
        earliest =
          (some ++ other)
          |> Enum.map(fn {_id, {min_i, _max_i}} -> min_i end)
          |> Enum.min()

        if earliest < split do
          fixup_split_for_tool_straddles(earliest, spans)
        else
          split
        end
    end
  end

  # Split the message list into `{older, recent}` while preserving the last K assistant
  # completion rounds (including any immediately preceding tool-call messages).
  defp split_preserve_last_k_rounds(msgs, k) when is_integer(k) and k >= 0 do
    comp_indices =
      msgs
      |> Enum.with_index()
      |> Enum.filter(fn {m, _i} -> assistant_completion_msg?(m) end)
      |> Enum.map(&elem(&1, 1))

    if length(comp_indices) <= k do
      {[], msgs}
    else
      last_k =
        comp_indices
        |> Enum.reverse()
        |> Enum.take(k)
        |> Enum.reverse()

      keep_start =
        last_k
        |> Enum.map(&round_start_for_completion(msgs, &1))
        |> Enum.min()

      spans = build_tool_call_spans(msgs)
      split = fixup_split_for_tool_straddles(keep_start, spans)

      Enum.split(msgs, split)
    end
  end

  @doc """
  Summarize only the older portion of the message list while preserving the last K
  assistant completion rounds and their tool-call messages.

  Returns an updated state map with `messages` compacted and `usage` recomputed.
  """
  @spec partial_compact(map(), map()) :: map()
  def partial_compact(state, opts) do
    keep_rounds = Map.get(opts, :keep_rounds, @compact_keep_rounds)
    target_pct = Map.get(opts, :target_pct, @compact_target_pct)

    messages = state.messages || []
    {older, recent} = split_preserve_last_k_rounds(messages, keep_rounds)

    if older == [] do
      state
    else
      name_msg =
        messages
        |> Enum.find(fn
          %{role: "system", content: content} when is_binary(content) ->
            content =~ ~r/Your name is .+\./

          _ ->
            false
        end)

      older_user = Enum.filter(older, &(&1.role == "user"))
      older_non_user = Enum.reject(older, &(&1.role == "user"))

      UI.info(
        "Compacting conversation",
        "Summarizing older assistant/tool history; retaining last #{keep_rounds} rounds and all user messages."
      )

      AI.Agent.Compactor
      |> AI.Agent.new(named?: false)
      |> AI.Agent.get_response(%{messages: older_non_user})
      |> case do
        {:ok, [summary_msg]} ->
          assembled =
            []
            |> Kernel.++(if name_msg, do: [name_msg], else: [])
            |> Kernel.++(older_user)
            |> Kernel.++([summary_msg])
            |> Kernel.++(recent)

          deduped =
            assembled
            |> Enum.uniq_by(fn msg ->
              {Map.get(msg, :role), Map.get(msg, :name), Map.get(msg, :content)}
            end)

          new_usage =
            deduped
            |> Enum.map(&Map.get(&1, :content))
            |> Enum.filter(&is_binary/1)
            |> Enum.map(&AI.PretendTokenizer.guesstimate_tokens/1)
            |> Enum.sum()

          UI.info(
            "Conversation compacted",
            "Kept all user messages and last #{keep_rounds} assistant rounds; est tokens: #{new_usage}/#{state.model.context}; target=#{target_pct}"
          )

          %{state | messages: deduped, usage: new_usage}

        {:error, :empty_after_filtering} ->
          UI.error("Compaction skipped", "Empty after filtering; original conversation retained")
          state

        {:error, reason} ->
          UI.warn("Compaction failed", inspect(reason, pretty: true))
          state
      end
    end
  end

  @doc """
  Full compaction of the entire message list via the summarizer agent.
  """
  @spec full_compact(map()) :: map()
  def full_compact(%{usage: usage, model: model, messages: messages} = state) do
    used_pct = Float.round(usage / model.context * 100, 1)
    context = model.context |> Util.format_number()
    used = usage |> Util.format_number()

    UI.info("Compacting conversation", "Context: #{used_pct}% (#{used}/#{context} tokens)")

    name_msg =
      messages
      |> Enum.find(fn
        %{role: "system", content: content} when is_binary(content) ->
          content =~ ~r/Your name is .+\./

        _ ->
          false
      end)

    user_msgs = Enum.filter(messages, &(&1.role == "user"))
    non_user_msgs = Enum.reject(messages, &(&1.role == "user"))

    AI.Agent.Compactor
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{messages: non_user_msgs})
    |> case do
      {:ok, [new_msg]} ->
        assembled =
          []
          |> Kernel.++(if name_msg, do: [name_msg], else: [])
          |> Kernel.++(user_msgs)
          |> Kernel.++([new_msg])

        new_tokens =
          assembled
          |> Enum.map(&Map.get(&1, :content))
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&AI.PretendTokenizer.guesstimate_tokens/1)
          |> Enum.sum()

        UI.info(
          "Conversation compacted",
          "Kept all user messages; assistant/tool context replaced with summary; est. tokens: #{new_tokens}/#{state.model.context}"
        )

        %{state | messages: assembled, usage: new_tokens}

      {:error, reason} ->
        UI.error("Compaction failed", inspect(reason, pretty: true))
        state
    end
  end
end
