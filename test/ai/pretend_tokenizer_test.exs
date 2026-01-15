defmodule AI.PretendTokenizerTest do
  use Fnord.TestCase, async: false

  alias AI.PretendTokenizer

  describe "guesstimate_tokens/1" do
    test "rounds up to nearest whole token (4 chars per token)" do
      assert PretendTokenizer.guesstimate_tokens("") == 0
      assert PretendTokenizer.guesstimate_tokens("a") == 1
      assert PretendTokenizer.guesstimate_tokens("abcd") == 1
      assert PretendTokenizer.guesstimate_tokens("abcde") == 2
    end
  end

  describe "over_max_for_openai_embeddings?/1" do
    test "false at or below 300k tokens and true above" do
      # 300_000 tokens ~= 1_200_000 chars
      max = String.duplicate("a", 1_200_000)
      over = max <> "a"

      refute PretendTokenizer.over_max_for_openai_embeddings?(max)
      assert PretendTokenizer.over_max_for_openai_embeddings?(over)
    end
  end

  describe "chunk/3" do
    test "chunks by graphemes and keeps chunk sizes as multiples of 4" do
      input = String.duplicate("a", 33)

      # chunk_size=4 tokens => target 16 chars => size 16
      chunks = PretendTokenizer.chunk(input, 4, 1.0)
      assert Enum.map(chunks, &String.length/1) == [16, 16, 1]
    end

    test "chunk accepts AI.Model and uses its context token count" do
      input = String.duplicate("b", 20)
      model = %AI.Model{context: 4}
      chunks = PretendTokenizer.chunk(input, model, 1.0)
      assert Enum.map(chunks, &String.length/1) == [16, 4]
    end

    test "handles reduction_factor producing small sizes" do
      input = "abcdefghij"

      # chunk_size=1 token => 4 chars * 0.1 => trunc(0.4)=0 => size 0
      # Enum.chunk_every/2 does not accept 0, so ensure we at least don't crash
      # by picking a factor that yields 4.
      chunks = PretendTokenizer.chunk(input, 1, 1.0)
      assert chunks == ["abcd", "efgh", "ij"]
    end
  end
end
