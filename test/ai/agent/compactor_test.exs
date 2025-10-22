defmodule AI.Agent.CompactorTest do
  use Fnord.TestCase, async: false

  @moduletag :capture_log

  setup do
    :ok = :meck.new(AI.Accumulator, [:no_link, :non_strict, :passthrough])

    on_exit(fn ->
      :meck.unload(AI.Accumulator)
    end)

    :ok
  end

  defp run_compactor(messages, attempts \\ 0) do
    AI.Agent.Compactor
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{messages: messages, attempts: attempts})
  end

  test "filters system/developer/notify_tool and <think> messages to empty transcript -> guard triggers no-op and no model calls" do
    # Messages that all get filtered -> transcript == [] -> "[]" == 2 bytes
    msgs = [
      %{role: "system", content: "sys"},
      %{role: "developer", content: "dev"},
      %{role: "tool", name: "notify_tool", content: "hi"},
      %{role: "assistant", content: "<think>internal</think>"}
    ]

    # No model calls should happen due to early guard
    :meck.expect(AI.Accumulator, :get_response, fn _opts ->
      flunk("AI.Accumulator.get_response/1 should not be called for empty transcript guard")
    end)

    {:error, :empty_after_filtering} = run_compactor(msgs)

    # Early guard: zero model calls
    assert :meck.num_calls(AI.Accumulator, :get_response, :_) == 0
  end

  test "successful compaction when transcript non-empty produces one system summary and single API call if sufficient" do
    msgs = [
      %{role: "user", content: String.duplicate("u", 10_000)}
    ]

    # Mock the completion to produce a very small summary, ensuring sufficient savings
    :meck.expect(AI.Accumulator, :get_response, fn _opts ->
      {:ok, %{response: "tiny"}}
    end)

    {:ok, [summary_msg]} = run_compactor(msgs)

    assert summary_msg.role == "developer"
    assert String.contains?(summary_msg.content, "Summary of conversation and research thus far:")

    # Only one call because savings should be well under 65% threshold
    assert :meck.num_calls(AI.Accumulator, :get_response, :_) == 1
  end

  test "transcript preserves non-notify tool calls and assistant messages (without <think>)" do
    msgs = [
      %{role: "tool", name: "other_tool", content: "tool-output"},
      %{role: "assistant", content: "visible reply"},
      %{role: "user", content: "ask"}
    ]

    :meck.expect(AI.Accumulator, :get_response, fn _opts ->
      {:ok, %{response: "ok"}}
    end)

    {:ok, [summary_msg]} = run_compactor(msgs)

    assert summary_msg.role == "developer"
    assert is_binary(summary_msg.content)

    assert :meck.num_calls(AI.Accumulator, :get_response, :_) == 1
  end

  test "returns error when compaction consistently produces larger summaries after all retries" do
    # Large enough transcript (> 512 bytes) to trigger retries
    msgs = [%{role: "user", content: String.duplicate("u", 1000)}]

    # Mock returns a bloated summary every time (larger than original)
    :meck.expect(AI.Accumulator, :get_response, fn _opts ->
      {:ok, %{response: String.duplicate("x", 2000)}}
    end)

    # Should try 4 times total (initial + 3 retries), then return error
    {:error, :compaction_failed} = run_compactor(msgs)

    # 1 initial + 3 retries = 4 total calls
    assert :meck.num_calls(AI.Accumulator, :get_response, :_) == 4
  end
end
