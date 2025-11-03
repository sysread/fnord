defmodule AI.Responses.CompactionTest do
  use Fnord.TestCase
  @moduletag :unit

  alias AI.Responses.Compaction, as: C

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

  test "partial_compact no-ops when completions <= keep_rounds" do
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

    opts = %{keep_rounds: 2, target_pct: 0.6}
    new_state = C.partial_compact(state, opts)
    assert new_state.messages == state.messages
    assert new_state.usage >= 0
  end

  test "partial_compact preserves tool-call msgs immediately preceding the last completion when covered by keep_rounds" do
    msgs = [
      user_msg("start"),
      assistant_msg("answer1"),
      user_msg("do tool"),
      tool_req("abc", "some_tool", "{\"x\":1}"),
      tool_res("abc", "some_tool", "result"),
      assistant_msg("answer2")
    ]

    state = %{model: %{context: 1000}, usage: 200, messages: msgs}

    opts = %{keep_rounds: 2, target_pct: 0.6}
    new_state = C.partial_compact(state, opts)

    recent_suffix = Enum.take(new_state.messages, -3)
    assert recent_suffix == Enum.slice(msgs, -3, 3)
  end
end
