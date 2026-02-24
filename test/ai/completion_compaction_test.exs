defmodule AI.Completion.CompactionTest do
  use Fnord.TestCase, async: false

  alias AI.Completion.Compaction

  test "skips already tersified messages" do
    msgs = [
      %{role: "assistant", content: "<fnord-meta:tersified /> Short"},
      %{role: "user", content: "latest user message"}
    ]

    {:ok, compacted, _usage} = Compaction.compact(msgs)

    assert compacted == msgs
  end

  test "compaction adds tersified marker for non-marked messages" do
    msgs = [
      %{role: "assistant", content: "This is a long assistant message that should be compacted."},
      %{role: "user", content: "latest user message"}
    ]

    {:ok, compacted, _usage} = Compaction.compact(msgs)

    assistant_msg = Enum.find(compacted, &(&1.role == "assistant"))

    assert is_map(assistant_msg)
    assert is_binary(assistant_msg.content)

    assert String.contains?(assistant_msg.content, "<fnord-meta:tersified />") or
             assistant_msg.content == "This is a long assistant message that should be compacted."
  end
end
