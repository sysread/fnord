defmodule AI.SplitterTest do
  use ExUnit.Case

  # Mock tokenizer that just splits on spaces insteead of generating tokens.
  defmodule MockTokenizer do
    @behaviour AI.Tokenizer

    @impl AI.Tokenizer
    def encode(text, _model) do
      text |> String.split()
    end

    @impl AI.Tokenizer
    def decode(tokens, _model) do
      tokens |> Enum.join(" ")
    end
  end

  setup do
    orig = Application.get_env(:fnord, :tokenizer_module)

    Application.put_env(:fnord, :tokenizer_module, MockTokenizer)

    on_exit(fn ->
      Application.put_env(:fnord, :tokenizer_module, orig)
    end)

    :ok
  end

  test "next_chunk/1" do
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
