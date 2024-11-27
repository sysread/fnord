defmodule AI.Tokenizer.SplitterTest do
  use ExUnit.Case

  # Mock tokenizer that just splits on spaces insteead of generating tokens.
  defmodule MockTokenizer do
    @behaviour AI.Tokenizer.Behaviour

    @impl AI.Tokenizer.Behaviour
    def encode(text) do
      text |> String.split()
    end

    @impl AI.Tokenizer.Behaviour
    def decode(tokens) do
      tokens |> Enum.join(" ")
    end
  end

  test "next_chunk/1" do
    input = "the quick brown fox jumps over the lazy dog"

    splitter = AI.Tokenizer.Splitter.new(input, 5, MockTokenizer)

    assert {"the quick brown", %{offset: 3} = splitter} =
             AI.Tokenizer.Splitter.next_chunk(splitter, "how now")

    assert {"fox jumps over", %{offset: 6} = splitter} =
             AI.Tokenizer.Splitter.next_chunk(splitter, "brown bureaucrat")

    assert {"the lazy", %{offset: 8} = splitter} =
             AI.Tokenizer.Splitter.next_chunk(splitter, "foo bar baz")

    assert {"dog", %{offset: 9} = splitter} =
             AI.Tokenizer.Splitter.next_chunk(splitter, "slack")

    assert %{done: true} = splitter
  end
end
