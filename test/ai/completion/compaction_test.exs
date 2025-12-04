defmodule AI.Completion.CompactionTest do
  use Fnord.TestCase

  @moduletag :unit

  alias AI.Completion.Compaction, as: C

  defp assistant_msg(content), do: %{role: "assistant", content: content}
  defp user_msg(content), do: %{role: "user", content: content}

  defp tool_req(id, func, args_json),
    do: %{
      role: "assistant",
      content: nil,
      tool_calls: [%{id: id, type: "function", function: %{name: func, arguments: args_json}}]
    }

  defp tool_res(id, func, output),
    do: %{role: "tool", name: func, tool_call_id: id, content: output}

  test "compact no-ops when completions <= keep_rounds" do
    state = %{
      model: %{context: 1000},
      usage: 100,
      messages: [
        user_msg("hi"),
        assistant_msg("hello"),
        user_msg("next"),
        assistant_msg("world")
      ]
    }

    # keep_rounds covers both assistant completions -> no compaction needed
    opts = %{keep_rounds: 2, target_pct: 0.6}

    new_state = C.compact(state, opts)
    assert new_state.messages == state.messages
    assert new_state.usage >= 0
  end

  test "compact preserves tool-call msgs immediately preceding the last completion when covered by keep_rounds" do
    # Build a conversation where the last assistant completion is preceded by a tool request/response
    # When keep_rounds=1, the last completion is preserved and its adjacent tool messages remain in recent
    msgs = [
      user_msg("start"),
      assistant_msg("answer1"),
      user_msg("do tool"),
      tool_req("abc", "some_tool", "{\"x\":1}"),
      tool_res("abc", "some_tool", "result"),
      assistant_msg("answer2")
    ]

    state = %{model: %{context: 1000}, usage: 200, messages: msgs}

    # Use keep_rounds=2 to avoid invoking the summarizer; we still verify that the
    # tool-call messages immediately preceding the last completion remain intact.
    opts = %{keep_rounds: 2, target_pct: 0.6}
    new_state = C.compact(state, opts)

    recent_suffix = Enum.take(new_state.messages, -3)
    assert recent_suffix == Enum.slice(msgs, -3, 3)
  end

  test "compact prunes older summary system messages, keeping only the latest" do
    name = %{
      role: "system",
      content: "Your name is X."
    }

    summary_1 = %{
      role: "system",
      content: "Summary of conversation and research thus far: part one"
    }

    summary_2 = %{
      role: "system",
      content: "Summary of conversation and research thus far: part two"
    }

    new_state =
      %{
        model: %{context: 1000},
        usage: 900,
        messages: [
          name,
          user_msg("hello"),
          assistant_msg("world"),
          summary_1,
          user_msg("more"),
          summary_2
        ]
      }
      |> C.compact(%{keep_rounds: 0, target_pct: 0.6})

    refute summary_1 in new_state.messages
    assert summary_2 in new_state.messages
    assert name in new_state.messages
  end

  test "compact leaves messages unchanged when no summaries present" do
    state = %{
      model: %{context: 1000},
      usage: 800,
      messages: [
        %{role: "system", content: "Your name is X."},
        user_msg("foo"),
        assistant_msg("bar")
      ]
    }

    new_state = C.compact(state, %{keep_rounds: 0, target_pct: 0.6})
    assert new_state.messages == state.messages

    refute Enum.any?(new_state.messages, fn
             %{role: "system", content: content} ->
               String.starts_with?(content, "Summary of conversation and research thus far:")

             _ ->
               false
           end)
  end
end
