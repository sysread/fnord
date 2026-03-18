defmodule AI.SplitterTest do
  use Fnord.TestCase, async: false

  test "next_chunk/1" do
    input = "aaaabbbbccccddddeeeeffff"

    # model with 2 token context, which leaves room for 2 estimated tokens per slice
    model = AI.Model.new("mst-3k", 2)

    splitter = AI.Splitter.new(input, model)

    assert {"aaaabb", %{input: "bbccccddddeeeeffff", done: false} = splitter} =
             AI.Splitter.next_chunk(splitter, "")

    assert {"", %{input: "", done: true} = splitter} =
             AI.Splitter.next_chunk(splitter, "1234")

    assert {:done, ^splitter} = AI.Splitter.next_chunk(splitter, "")
  end
end
