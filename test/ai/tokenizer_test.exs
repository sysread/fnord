defmodule AI.TokenSplitterTest do
  use ExUnit.Case

  # Mock tokenizer that just splits on spaces insteead of generating tokens.
  defmodule MockTokenizer do
    @behaviour AI.Tokenizer

    @impl AI.Tokenizer
    def encode(text) do
      text |> String.split()
    end

    @impl AI.Tokenizer
    def decode(tokens) do
      tokens |> Enum.join(" ")
    end
  end

  test "next_chunk/1" do
    input = "the quick brown fox jumps over the lazy dog"

    splitter = AI.TokenSplitter.new(input, 5, MockTokenizer)

    assert {"the quick brown", %{offset: 3} = splitter} =
             AI.TokenSplitter.next_chunk(splitter, "how now")

    assert {"fox jumps over", %{offset: 6} = splitter} =
             AI.TokenSplitter.next_chunk(splitter, "brown bureaucrat")

    assert {"the lazy", %{offset: 8} = splitter} =
             AI.TokenSplitter.next_chunk(splitter, "foo bar baz")

    assert {"dog", %{offset: 9} = splitter} =
             AI.TokenSplitter.next_chunk(splitter, "slack")

    assert %{done: true} = splitter
  end
end
