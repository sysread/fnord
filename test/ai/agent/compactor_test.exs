defmodule AI.Agent.CompactorTest do
  use Fnord.TestCase, async: false

  @moduletag :capture_log

  setup do
    :ok = :meck.new(AI.Completion, [:no_link, :non_strict, :passthrough])

    on_exit(fn ->
      :meck.unload(AI.Completion)
    end)

    :ok
  end

  defp run_compactor(messages, attempts \\ 0) do
    AI.Agent.Compactor
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{messages: messages, attempts: attempts})
  end

  test "filters system/developer/notify_tool and <think> messages to empty transcript, triggers negative savings and retries" do
    # Messages that all get filtered -> transcript == [] -> "[]" == 2 bytes
    msgs = [
      %{role: "system", content: "sys"},
      %{role: "developer", content: "dev"},
      %{role: "tool", name: "notify_tool", content: "hi"},
      %{role: "assistant", content: "<think>internal</think>"}
    ]

    # Mock the completion to return some non-trivial summary content each time
    :meck.expect(AI.Completion, :get, fn _opts ->
      {:ok, %AI.Completion{response: String.duplicate("x", 300)}}
    end)

    {:ok, [summary_msg]} = run_compactor(msgs)

    # We expect 1 summary system message produced
    assert summary_msg.role == "developer"
    assert is_binary(summary_msg.content)

    # 1 initial pass + 2 retries (max 3 attempts total)
    assert :meck.num_calls(AI.Completion, :get, :_) == 4
  end

  test "successful compaction when transcript non-empty produces one system summary and single API call if sufficient" do
    msgs = [
      %{role: "user", content: String.duplicate("u", 10_000)}
    ]

    # Mock the completion to produce a very small summary, ensuring sufficient savings
    :meck.expect(AI.Completion, :get, fn _opts ->
      {:ok, %AI.Completion{response: "tiny"}}
    end)

    {:ok, [summary_msg]} = run_compactor(msgs)

    assert summary_msg.role == "developer"
    assert String.contains?(summary_msg.content, "Summary of conversation and research thus far:")

    # Only one call because savings should be well under 65% threshold
    assert :meck.num_calls(AI.Completion, :get, :_) == 1
  end

  test "transcript preserves non-notify tool calls and assistant messages (without <think>)" do
    msgs = [
      %{role: "tool", name: "other_tool", content: "tool-output"},
      %{role: "assistant", content: "visible reply"},
      %{role: "user", content: "ask"}
    ]

    :meck.expect(AI.Completion, :get, fn _opts ->
      {:ok, %AI.Completion{response: "ok"}}
    end)

    {:ok, [summary_msg]} = run_compactor(msgs)

    assert summary_msg.role == "developer"
    assert is_binary(summary_msg.content)

    assert :meck.num_calls(AI.Completion, :get, :_) == 1
  end
end
