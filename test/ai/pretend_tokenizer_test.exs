defmodule AI.PretendTokenizerTest do
  use Fnord.TestCase, async: false

  alias AI.PretendTokenizer

  describe "guesstimate_tokens/1" do
    test "rounds up to nearest whole token (3 chars per token)" do
      assert PretendTokenizer.guesstimate_tokens("") == 0
      assert PretendTokenizer.guesstimate_tokens("a") == 1
      assert PretendTokenizer.guesstimate_tokens("abc") == 1
      assert PretendTokenizer.guesstimate_tokens("abcd") == 2
      assert PretendTokenizer.guesstimate_tokens("abcde") == 2
    end
  end

  describe "over_max_for_openai_embeddings?/1" do
    test "false at or below 300k tokens and true above" do
      # 300_000 tokens ~= 900_000 chars
      max = String.duplicate("a", 900_000)
      over = max <> "a"

      refute PretendTokenizer.over_max_for_openai_embeddings?(max)
      assert PretendTokenizer.over_max_for_openai_embeddings?(over)
    end
  end

  describe "chunk/3" do
    test "chunks by graphemes using the conservative token estimate" do
      input = String.duplicate("a", 33)

      # chunk_size=4 tokens => target 12 chars
      chunks = PretendTokenizer.chunk(input, 4, 1.0)
      assert Enum.map(chunks, &String.length/1) == [12, 12, 9]
    end

    test "chunk accepts AI.Model and uses its context token count" do
      input = String.duplicate("b", 20)
      model = %AI.Model{context: 4}
      chunks = PretendTokenizer.chunk(input, model, 1.0)
      assert Enum.map(chunks, &String.length/1) == [12, 8]
    end

    test "handles small token targets without producing empty chunks" do
      input = "abcdefghij"

      chunks = PretendTokenizer.chunk(input, 1, 1.0)
      assert chunks == ["abc", "def", "ghi", "j"]
    end

    test "never produces a zero-sized chunk for a very small reduction factor" do
      input = String.duplicate("x", 5)
      chunks = PretendTokenizer.chunk(input, 1, 0.01)

      refute Enum.any?(chunks, &(String.length(&1) == 0))
      assert chunks == ["x", "x", "x", "x", "x"]
    end
  end
end
