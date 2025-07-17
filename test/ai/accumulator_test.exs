defmodule AI.AccumulatorTest do
  use Fnord.TestCase, async: false

  alias AI.{Accumulator, Completion, Splitter}

  setup do
    :meck.new(Completion, [:no_link, :passthrough])
    on_exit(fn -> :meck.unload(Completion) end)
    :ok
  end

  defp minimal_accumulator() do
    model = %{context: 100}

    %Accumulator{
      model: model,
      splitter: Splitter.new("test input", model),
      buffer: "",
      prompt: "",
      question: "",
      toolbox: nil,
      completion_args: [],
      line_numbers: false
    }
  end

  test "process_chunk returns success on first try" do
    :meck.expect(Completion, :get, fn _ -> {:ok, %{response: "ok"}} end)

    acc = minimal_accumulator()
    assert {:ok, %{buffer: "ok"}} = Accumulator.process_chunk(acc)
    assert :meck.num_calls(Completion, :get, :_) == 1
  end

  test "process_chunk backs off n times then returns success" do
    tries = 3
    counter = :counters.new(1, [:atomics])

    :meck.expect(Completion, :get, fn _ ->
      n = :counters.get(counter, 1)

      if n < tries - 1 do
        :counters.add(counter, 1, 1)
        {:error, :context_length_exceeded}
      else
        {:ok, %{response: "final-ok"}}
      end
    end)

    acc = minimal_accumulator()
    assert {:ok, %{buffer: "final-ok"}} = Accumulator.process_chunk(acc)

    # 1 success on 3rd call + 2 context_length_exceeded calls (1.0 and 0.8 fractions) = 3 total calls
    assert :meck.num_calls(Completion, :get, :_) == tries
  end

  test "process_chunk returns error immediately on non-backoff error" do
    :meck.expect(Completion, :get, fn _ -> {:error, %Completion{response: "some other error"}} end)

    acc = minimal_accumulator()
    assert {:error, "some other error"} = Accumulator.process_chunk(acc)
    assert :meck.num_calls(Completion, :get, :_) == 1
  end

  test "process_chunk gives up after max retries" do
    :meck.expect(Completion, :get, fn _ ->
      {:error, :context_length_exceeded}
    end)

    acc = minimal_accumulator()

    assert {:error, "context window length exceeded: unable to back off further to fit the input"} =
             Accumulator.process_chunk(acc)

    # Should max at 3 calls:
    # Linear backoff tries at fractions 1.0, 0.8, 0.6
    # After 0.6 fails, next fraction 0.4 is below threshold 0.6, so it gives up immediately
    assert :meck.num_calls(Completion, :get, :_) == 3
  end
end
