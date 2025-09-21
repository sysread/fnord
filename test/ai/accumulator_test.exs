defmodule AI.Accumulator.Test do
  use Fnord.TestCase, async: false

  @moduledoc """
  Unit tests for AI.Accumulator covering missing options, multi‐chunk, backoff,
  and line_numbers.
  """

  setup do
    :meck.new(AI.Splitter, [:no_link, :non_strict, :passthrough])
    :meck.new(AI.Completion, [:no_link, :non_strict, :passthrough])

    on_exit(fn ->
      :meck.unload(AI.Splitter)
      :meck.unload(AI.Completion)
    end)
  end

  test "get_response/1 returns error when missing required option" do
    assert {:error, :missing_required_option} = AI.Accumulator.get_response([])
  end

  test "processes multiple chunks and then finalizes" do
    # Define fake splitter states
    model = AI.Model.new("fake", 100)
    splitter0 = %AI.Splitter{done: false, input: "dummy0", model: model}
    splitter1 = %AI.Splitter{done: false, input: "dummy1", model: model}
    splitter2 = %AI.Splitter{done: true, input: "", model: model}

    # Mock Splitter.new/2 and next_chunk/3
    :meck.expect(AI.Splitter, :new, fn _input, _model -> splitter0 end)

    :meck.expect(AI.Splitter, :next_chunk, fn
      ^splitter0, _user, _max -> {"chunk1", splitter1}
      ^splitter1, _user, _max -> {"chunk2", splitter2}
    end)

    # Mock Completion.get/1 to return two partials and final
    Process.put(:call_count, 0)

    :meck.expect(AI.Completion, :get, fn _args ->
      n = Process.get(:call_count)
      Process.put(:call_count, n + 1)

      case n do
        0 -> {:ok, %AI.Completion{response: "resp1"}}
        1 -> {:ok, %AI.Completion{response: "resp2"}}
        _ -> {:ok, %AI.Completion{response: "FINAL"}}
      end
    end)

    # Execute and assert
    opts = [model: model, prompt: "PROMPT", input: "IGNORED"]
    assert {:ok, %AI.Completion{response: "FINAL"}} = AI.Accumulator.get_response(opts)
    assert :meck.num_calls(AI.Splitter, :next_chunk, :_) == 2
    assert :meck.num_calls(AI.Completion, :get, :_) == 3
  end

  test "backs off on context_length_exceeded then succeeds" do
    # Mock splitter for a single chunk then done
    model = AI.Model.new("fake", 20)
    _splitter0 = %AI.Splitter{done: false, input: "input", model: model}
    splitter1 = %AI.Splitter{done: true, input: "", model: model}

    :meck.expect(AI.Splitter, :next_chunk, fn _sp, _user, _max -> {"chunk", splitter1} end)

    # Mock Completion.get/1 with backoff
    Process.put(:call_count, 0)

    :meck.expect(AI.Completion, :get, fn _args ->
      case Process.get(:call_count) do
        0 ->
          Process.put(:call_count, 1)
          {:error, :context_length_exceeded, 42}

        1 ->
          Process.put(:call_count, 2)
          {:ok, %AI.Completion{response: "buf"}}

        _ ->
          {:ok, %AI.Completion{response: "DONE"}}
      end
    end)

    # Execute and assert backoff path
    opts = [model: model, prompt: "P", input: "X"]
    assert {:ok, %AI.Completion{response: "DONE"}} = AI.Accumulator.get_response(opts)
    assert :meck.num_calls(AI.Completion, :get, :_) == 3
  end

  test "backoff eventually fails when below threshold" do
    # Mock single chunk then done
    model = AI.Model.new("fake", 20)
    splitter0 = %AI.Splitter{done: false, input: "input", model: model}
    splitter1 = %AI.Splitter{done: true, input: "", model: model}
    :meck.expect(AI.Splitter, :new, fn _input, _model -> splitter0 end)
    :meck.expect(AI.Splitter, :new, fn _input, _model -> splitter0 end)
    :meck.expect(AI.Splitter, :next_chunk, fn _sp, _user, _max -> {"chunk", splitter1} end)
    # Always return context length exceeded
    :meck.expect(AI.Completion, :get, fn _args -> {:error, :context_length_exceeded, 100} end)

    opts = [model: model, prompt: "P", input: "X"]
    assert {:error, msg} = AI.Accumulator.get_response(opts)
    assert msg =~ "unable to back off further"
    assert :meck.num_calls(AI.Completion, :get, :_) >= 3
  end

  test "line_numbers: true prefixes each line before chunking" do
    raw_input = "apple\nbanana\n"
    model = AI.Model.new("fake", 50)
    # Expect Splitter.new to receive numbered input
    splitter = %AI.Splitter{done: true, input: "", model: model}

    :meck.expect(AI.Splitter, :new, fn input, ^model ->
      send(self(), {:transformed, input})
      splitter
    end)

    # Completion.get returns a dummy response
    :meck.expect(AI.Completion, :get, fn _args -> {:ok, %AI.Completion{response: "resp"}} end)

    opts = [model: model, prompt: "P", input: raw_input, line_numbers: true]
    assert {:ok, %AI.Completion{response: _}} = AI.Accumulator.get_response(opts)
    assert_receive {:transformed, numbered}
    assert numbered =~ "1|apple"
    assert numbered =~ "2|banana"
  end
end
