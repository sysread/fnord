defmodule AI.SplitterTest do
  use Fnord.TestCase

  setup do: set_config(:tokenizer, MockTokenizer)

  test "next_chunk/1" do
    MockTokenizer
    |> Mox.stub(:encode, fn text, _model -> String.split(text) end)
    |> Mox.stub(:decode, fn tokens, _model -> Enum.join(tokens, " ") end)

    input = "the quick brown fox jumps over the lazy dog"

    splitter = AI.Splitter.new(input, 5, "mst-3k")

    assert {"the quick brown", %{offset: 3} = splitter} =
             AI.Splitter.next_chunk(splitter, "how now")

    assert {"fox jumps over", %{offset: 6} = splitter} =
             AI.Splitter.next_chunk(splitter, "brown bureaucrat")

    assert {"the lazy", %{offset: 8} = splitter} =
             AI.Splitter.next_chunk(splitter, "foo bar baz")

    assert {"dog", %{offset: 9} = splitter} =
             AI.Splitter.next_chunk(splitter, "slack")

    assert %{done: true} = splitter
  end
end
