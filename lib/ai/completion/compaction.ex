defmodule AI.Completion.Compaction do
  @moduledoc """
  Compacts conversation history for AI completion requests. Compacts by
  summarizing tool calls and assistant messages following each user message,
  while preserving user messages and special system messages.
  """

  @spec compact(map(), map()) :: map()
  @spec compact(map(), map()) :: map()
  def compact(state, opts) do
    with {:ok, {name_msg, msgs}} <- extract_name_and_msgs(state),
         {:ok, segments} <- build_segments(msgs),
         {:ok, first_pass} <- run_first_pass(state, name_msg, segments, opts),
         {:ok, final_state} <- maybe_run_second_pass(state, name_msg, first_pass, opts) do
      final_state
    else
      {:error, _reason} ->
        # On any internal error, log and preserve the original state
        UI.warn(
          "Compaction skipped",
          "Internal error during compaction; original history preserved"
        )

        state
    end
  end

  defp extract_name_and_msgs(state) do
    messages = Map.get(state, :messages, [])

    name_msg =
      Enum.find(messages, fn
        %{role: "system", content: content} when is_binary(content) ->
          content =~ ~r/Your name is .+\./

        _ ->
          false
      end)

    msgs =
      case name_msg do
        nil -> messages
        msg -> List.delete(messages, msg)
      end

    {:ok, {name_msg, msgs}}
  end

  defp build_segments(msgs) do
    {segments, last_user, last_non_user} =
      Enum.reduce(msgs, {[], nil, []}, fn msg, {segs, curr_user, curr_non_user} ->
        if Map.get(msg, :role) == "user" do
          new_segs =
            if curr_user do
              segs ++ [%{user: curr_user, non_user: curr_non_user}]
            else
              segs
            end

          {new_segs, msg, []}
        else
          {segs, curr_user, curr_non_user ++ [msg]}
        end
      end)

    segments =
      if last_user do
        segments ++ [%{user: last_user, non_user: last_non_user}]
      else
        segments
      end

    {:ok, segments}
  end

  defp run_first_pass(_state, name_msg, segments, _opts) do
    {head_segments, last_segment_list} =
      case segments do
        [] -> {[], []}
        _ -> Enum.split(segments, -1)
      end

    {compacted_head, ctx_after_head} =
      Enum.reduce(head_segments, {[], []}, fn %{user: user, non_user: non_user}, {acc, ctx} ->
        to_summarize = ctx ++ [user] ++ non_user

        summary_result =
          AI.Agent.Compactor
          |> AI.Agent.new(named?: false)
          |> AI.Agent.get_response(%{messages: to_summarize})

        case summary_result do
          {:ok, [summary_msg]} ->
            msgs = [user, summary_msg]
            {acc ++ msgs, ctx ++ msgs}

          _ ->
            msgs = [user] ++ non_user
            {acc ++ msgs, ctx ++ msgs}
        end
      end)

    raw_last_msgs =
      case last_segment_list do
        [%{user: user, non_user: non_user}] -> [user] ++ non_user
        _ -> []
      end

    first_pass_messages =
      if(name_msg, do: [name_msg], else: []) ++
        compacted_head ++
        raw_last_msgs

    new_usage_1 =
      first_pass_messages
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&AI.PretendTokenizer.guesstimate_tokens/1)
      |> Enum.sum()

    {:ok,
     %{
       messages: first_pass_messages,
       usage: new_usage_1,
       compacted_head: compacted_head,
       ctx_after_head: ctx_after_head,
       last_segment_list: last_segment_list
     }}
  end

  defp maybe_run_second_pass(state, name_msg, first_pass, opts) do
    %{
      messages: first_msgs,
      usage: usage_1,
      compacted_head: compacted_head,
      ctx_after_head: ctx_after_head,
      last_segment_list: last_segment_list
    } = first_pass

    target_pct = Map.get(opts, :target_pct, 0.8)

    if last_segment_list == [] or
         meets_target?(state.model.context, usage_1, target_pct) do
      UI.info("Compaction run", "Simplified partial compaction completed")
      {:ok, %{state | messages: first_msgs, usage: usage_1}}
    else
      {compacted_last, _} =
        Enum.reduce(last_segment_list, {[], ctx_after_head}, fn %{user: user, non_user: non_user},
                                                                {acc, ctx} ->
          to_summarize = ctx ++ [user] ++ non_user

          summary_result =
            AI.Agent.Compactor
            |> AI.Agent.new(named?: false)
            |> AI.Agent.get_response(%{messages: to_summarize})

          case summary_result do
            {:ok, [summary_msg]} ->
              msgs = [user, summary_msg]
              {acc ++ msgs, ctx ++ msgs}

            _ ->
              msgs = [user] ++ non_user
              {acc ++ msgs, ctx ++ msgs}
          end
        end)

      second_pass_messages =
        if(name_msg, do: [name_msg], else: []) ++
          compacted_head ++
          compacted_last

      new_usage_2 =
        second_pass_messages
        |> Enum.map(&Map.get(&1, :content))
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&AI.PretendTokenizer.guesstimate_tokens/1)
        |> Enum.sum()

      UI.info("Compaction run", "Simplified partial compaction completed")
      {:ok, %{state | messages: second_pass_messages, usage: new_usage_2}}
    end
  end

  defp meets_target?(context, usage, target_pct) when is_number(context) and context > 0 do
    usage <= target_pct * context
  end

  defp meets_target?(_context, _usage, _target_pct), do: true
end
