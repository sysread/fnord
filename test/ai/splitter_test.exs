defmodule AI.SplitterTest do
  use Fnord.TestCase

  test "next_chunk/1" do
    input = "aaaabbbbccccddddeeeeffff"

    # model with 2 token context, which means we can process 8 characters
    model = AI.Model.new("mst-3k", 2)

    splitter = AI.Splitter.new(input, model)

    # 2 tokens = 8 characters, w/o any bespoke input
    assert {"aaaabbbb", %{input: "ccccddddeeeeffff", done: false} = splitter} =
             AI.Splitter.next_chunk(splitter, "")

    # bespoke input of 4 characters means we can only process 4 more characters
    assert {"cccc", %{input: "ddddeeeeffff", done: false} = splitter} =
             AI.Splitter.next_chunk(splitter, "1234")

    # fractional tokens are rounded up
    assert {"dddd", %{input: "eeeeffff", done: false} = splitter} =
             AI.Splitter.next_chunk(splitter, "12")

    # Final chunk, no bespoke input, done is true
    assert {"eeeeffff", %{input: "", done: true}} =
             AI.Splitter.next_chunk(splitter, "")
  end
end
