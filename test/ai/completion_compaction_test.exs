defmodule AI.Completion.CompactionTest do
  use Fnord.TestCase, async: true

  alias AI.Completion.Compaction

  # Compaction's pipeline: tersify each message before the latest user msg
  # (skipping already-marked ones), and if that saves < 30%, fall through to
  # summarizing the whole transcript. The stubs below feed canned model
  # responses through the real AI.Completion loop, so these tests exercise
  # the actual pipeline rather than its error-fallback path.

  defp drain_completions(acc \\ []) do
    receive do
      {:completion, msgs} -> drain_completions([msgs | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "does not re-tersify already tersified messages" do
    test_pid = self()

    canned_completion(fn msgs ->
      send(test_pid, {:completion, msgs})
      {:ok, :msg, "summary of the conversation", 1}
    end)

    msgs = [
      %{role: "assistant", content: "<fnord-meta:tersified /> Short"},
      %{role: "user", content: "latest user message"}
    ]

    # The lone assistant message is already marked, so tersification is a
    # no-op; zero savings forces the summarize fallback.
    {:ok, compacted, _usage} = Compaction.compact(msgs)

    assert [%{content: summary}] = compacted
    assert summary =~ "<fnord-meta:summary />"
    assert summary =~ "summary of the conversation"

    # No model call may carry the tersify system prompt - the marked message
    # must be skipped, not re-compacted. (The calls we do see belong to the
    # summarize fallback.)
    calls = drain_completions()
    assert calls != []

    refute Enum.any?(calls, fn call ->
             Enum.any?(call, fn
               %{content: content} when is_binary(content) ->
                 content =~ "restating them as tersely"

               _ ->
                 false
             end)
           end)
  end

  # Regression: tersify_msg's inner completion runs with compact?: false, so
  # an oversized message surfaces {:error, :context_length_exceeded, usage} -
  # a three-element tuple its case once had no clause for. The tersify task
  # crashed, killing the very completion compaction was trying to rescue.
  # The message must instead pass through untersified to the summarize
  # fallback.
  test "a message too large to tersify defers to summarization instead of crashing" do
    canned_completion(fn msgs ->
      tersify_call? =
        Enum.any?(msgs, fn
          %{content: content} when is_binary(content) ->
            content =~ "restating them as tersely"

          _ ->
            false
        end)

      if tersify_call? do
        {:error, :context_length_exceeded, 999_999}
      else
        {:ok, :msg, "summary of the conversation", 1}
      end
    end)

    msgs = [
      %{role: "assistant", content: "pretend this message is enormous"},
      %{role: "user", content: "latest user message"}
    ]

    {:ok, compacted, _usage} = Compaction.compact(msgs)

    assert [%{content: summary}] = compacted
    assert summary =~ "<fnord-meta:summary />"
    assert summary =~ "summary of the conversation"
  end

  test "tersifies unmarked messages and adds the tersified marker" do
    long =
      String.duplicate("This is a long assistant message that should be compacted. ", 20)

    canned_completion("terse")

    msgs = [
      %{role: "assistant", content: long},
      %{role: "user", content: "latest user message"}
    ]

    # The canned reply shrinks the transcript far past the 30% savings bar,
    # so the pipeline stops after tersification - no summarize fallback.
    {:ok, compacted, _usage} = Compaction.compact(msgs)

    assistant_msg = Enum.find(compacted, &(&1.role == "assistant"))
    assert assistant_msg.content == "<fnord-meta:tersified />terse"

    # Everything from the latest user message on is retained untouched.
    assert %{role: "user", content: "latest user message"} = List.last(compacted)
  end
end
