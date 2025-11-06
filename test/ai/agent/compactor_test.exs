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
      %{role: "user", content: String.duplicate("u", 1000)},
      %{role: "assistant", content: String.duplicate("a", 9000)}
    ]

    # Mock the completion to produce a valid summary (>100 tokens) with sufficient savings
    :meck.expect(AI.Accumulator, :get_response, fn _opts ->
      {:ok,
       %{
         response:
           "# User Request\nThe user asked about implementing a new feature.\n\n# Key Findings\nDiscovered multiple files that need modification. The main logic resides in core.ex and tests are in core_test.exs.\n\n# Current Status\nThe assistant was analyzing the codebase structure and identifying the best approach for implementing the requested feature. Next steps include modifying the core module and adding test coverage."
       }}
    end)

    {:ok, [summary_msg]} = run_compactor(msgs)

    assert summary_msg.role == "developer"
    assert String.contains?(summary_msg.content, "Summary of conversation and research thus far:")

    # Only one call because savings should be well under 65% threshold
    assert :meck.num_calls(AI.Accumulator, :get_response, :_) == 1
  end

  test "transcript preserves non-notify tool calls and assistant messages (without <think>)" do
    msgs = [
      %{role: "tool", name: "other_tool", content: String.duplicate("tool-output data ", 100)},
      %{role: "assistant", content: String.duplicate("visible reply with details ", 100)},
      %{role: "user", content: String.duplicate("ask about something ", 50)}
    ]

    :meck.expect(AI.Accumulator, :get_response, fn _opts ->
      {:ok,
       %{
         response:
           "# User Request\nUser asked a question about the system behavior and functionality.\n\n# Key Findings\nTool outputs were generated showing relevant information about the codebase. The assistant provided a visible reply addressing the user's question with detailed context.\n\n# Current Status\nThe conversation included tool execution and assistant response. The interaction was complete at the point of compaction with all information preserved."
       }}
    end)

    {:ok, [summary_msg]} = run_compactor(msgs)

    assert summary_msg.role == "developer"
    assert is_binary(summary_msg.content)

    assert :meck.num_calls(AI.Accumulator, :get_response, :_) == 1
  end

  test "returns error when compaction consistently produces larger summaries after all retries" do
    # Large enough transcript (> 512 bytes) to trigger retries
    msgs = [
      %{role: "assistant", content: String.duplicate("a", 1000)}
    ]

    # Mock returns a bloated summary every time (larger than original)
    :meck.expect(AI.Accumulator, :get_response, fn _opts ->
      {:ok, %{response: String.duplicate("x", 2000)}}
    end)

    # Should try 4 times total (initial + 3 retries), then return error
    {:error, :compaction_failed} = run_compactor(msgs)

    # 1 initial + 3 retries = 4 total calls
    assert :meck.num_calls(AI.Accumulator, :get_response, :_) == 4
  end

  test "user-only transcripts are excluded from compaction (empty after filtering)" do
    msgs = [
      %{role: "user", content: String.duplicate("u", 5000)}
    ]

    :meck.expect(AI.Accumulator, :get_response, fn _opts ->
      flunk("should not call model when transcript is user-only")
    end)

    {:error, :empty_after_filtering} = run_compactor(msgs)

    assert :meck.num_calls(AI.Accumulator, :get_response, :_) == 0
  end
end
