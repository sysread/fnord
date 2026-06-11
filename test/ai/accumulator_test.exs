defmodule AI.Accumulator.Test do
  use Fnord.TestCase, async: true

  @moduledoc """
  Unit tests for AI.Accumulator covering missing options, multi-chunk, backoff,
  and line_numbers. The real AI.Splitter runs (it is deterministic char math
  over PretendTokenizer estimates); model responses are canned at the
  completion-API boundary, keyed on the accumulator's chunk vs finalize
  system prompts.
  """

  # The accumulator's two stages are distinguishable by system prompt: chunk
  # passes open with "You are processing input chunks in sequence", and the
  # finalize pass with "You have processed the user's input in chunks".
  defp finalize_call?(msgs) do
    Enum.any?(msgs, fn
      %{content: content} when is_binary(content) ->
        content =~ "You have processed the user's input in chunks"

      _ ->
        false
    end)
  end

  test "get_response/1 returns error when missing required option" do
    assert {:error, :missing_required_option} = AI.Accumulator.get_response([])
  end

  test "processes multiple chunks and then finalizes" do
    # Context of 100 tokens leaves room for ~250 input chars per chunk after
    # the accumulator preamble, so 600 chars force at least two chunks.
    model = AI.Model.new("fake", 100)
    input = String.duplicate("lorem ipsum dolor sit amet ", 22)

    test_pid = self()

    canned_completion(fn msgs ->
      send(test_pid, {:completion, msgs})

      if finalize_call?(msgs) do
        {:ok, :msg, "FINAL", 0}
      else
        n = Process.get(:chunk_calls, 0) + 1
        Process.put(:chunk_calls, n)
        {:ok, :msg, "resp#{n}", 0}
      end
    end)

    opts = [model: model, prompt: "PROMPT", input: input]
    assert {:ok, %AI.Completion{response: "FINAL"}} = AI.Accumulator.get_response(opts)

    # Drain the captured completions: several chunk passes, then one finalize.
    calls =
      Stream.repeatedly(fn ->
        receive do
          {:completion, msgs} -> msgs
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    {final_calls, chunk_calls} = Enum.split_with(calls, &finalize_call?/1)
    assert length(final_calls) == 1
    assert length(chunk_calls) >= 2

    # Continuity: the second chunk's accumulator carries the first response.
    second_chunk = Enum.at(chunk_calls, 1)
    user_content = second_chunk |> Enum.map(&Map.get(&1, :content)) |> Enum.join("\n")
    assert user_content =~ "resp1"

    # The finalize pass receives the last chunk response in its buffer.
    final_content =
      final_calls |> hd() |> Enum.map(&Map.get(&1, :content)) |> Enum.join("\n")

    assert final_content =~ "resp#{length(chunk_calls)}"
  end

  test "backs off on context_length_exceeded then succeeds" do
    model = AI.Model.new("fake", 20)

    test_pid = self()

    canned_completion(fn msgs ->
      send(test_pid, {:completion, msgs})

      cond do
        finalize_call?(msgs) ->
          {:ok, :msg, "DONE", 0}

        Process.get(:chunk_calls, 0) == 0 ->
          Process.put(:chunk_calls, 1)
          {:error, :context_length_exceeded, 42}

        true ->
          {:ok, :msg, "buf", 0}
      end
    end)

    # compact?: false keeps the completion loop from trying to rescue the
    # canned context-length error itself (its compaction retry would spawn
    # extra completions); the 3-tuple surfaces directly to the accumulator's
    # own backoff, which is what this test exercises.
    opts = [model: model, prompt: "P", input: "X", compact?: false]
    assert {:ok, %AI.Completion{response: "DONE"}} = AI.Accumulator.get_response(opts)

    # Three model calls: the failed chunk pass, the backed-off retry, and
    # the finalize pass.
    assert_received {:completion, _}
    assert_received {:completion, _}
    assert_received {:completion, _}
    refute_received {:completion, _}
  end

  test "backoff eventually fails when below threshold" do
    model = AI.Model.new("fake", 20)

    test_pid = self()

    canned_completion(fn _msgs ->
      send(test_pid, {:completion, :called})
      {:error, :context_length_exceeded, 100}
    end)

    opts = [model: model, prompt: "P", input: "X", compact?: false]
    assert {:error, msg} = AI.Accumulator.get_response(opts)
    assert msg =~ "unable to back off further"

    # Backoff walks frac 1.0 -> 0.8 -> 0.6 before giving up.
    assert_received {:completion, :called}
    assert_received {:completion, :called}
    assert_received {:completion, :called}
  end

  test "line_numbers: true prefixes each line before chunking" do
    raw_input = "apple\nbanana\n"
    model = AI.Model.new("fake", 50)

    test_pid = self()

    canned_completion(fn msgs ->
      send(test_pid, {:completion, msgs})
      {:ok, :msg, "resp", 0}
    end)

    opts = [model: model, prompt: "P", input: raw_input, line_numbers: true]
    assert {:ok, %AI.Completion{response: "resp"}} = AI.Accumulator.get_response(opts)

    # The first (chunk) completion must receive the hashline-numbered input.
    assert_received {:completion, chunk_msgs}
    content = chunk_msgs |> Enum.map(&Map.get(&1, :content)) |> Enum.join("\n")
    assert content =~ ~r/1:[0-9a-f]{4}\|apple/
    assert content =~ ~r/2:[0-9a-f]{4}\|banana/
  end
end
