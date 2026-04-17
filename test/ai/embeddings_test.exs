defmodule AI.EmbeddingsTest do
  use Fnord.TestCase, async: true

  describe "get/1" do
    test "rejects empty input" do
      assert {:error, "empty input"} = AI.Embeddings.get("")
    end

    test "rejects whitespace-only input" do
      assert {:error, "empty input"} = AI.Embeddings.get("   \n  ")
    end

    test "returns pool_not_running when pool is not started" do
      assert {:error, :pool_not_running} = AI.Embeddings.get("hello")
    end
  end

  describe "model_name/0" do
    test "returns the local model name" do
      assert AI.Embeddings.model_name() == "all-MiniLM-L12-v2"
    end
  end

  describe "dimensions/0" do
    test "returns 384" do
      assert AI.Embeddings.dimensions() == 384
    end
  end

  describe "cosine_similarity/2" do
    test "identical vectors return 1.0" do
      v = [1.0, 2.0, 3.0]
      assert_in_delta AI.Embeddings.cosine_similarity(v, v), 1.0, 1.0e-9
    end

    test "orthogonal vectors return 0.0" do
      assert AI.Embeddings.cosine_similarity([1.0, 0.0], [0.0, 1.0]) == 0.0
    end

    test "opposing vectors return -1.0" do
      assert_in_delta AI.Embeddings.cosine_similarity([1.0, 2.0], [-1.0, -2.0]), -1.0, 1.0e-9
    end

    test "empty vectors return 0.0" do
      assert AI.Embeddings.cosine_similarity([], [1.0]) == 0.0
      assert AI.Embeddings.cosine_similarity([1.0], []) == 0.0
    end

    test "mismatched lengths return 0.0" do
      assert AI.Embeddings.cosine_similarity([1.0, 2.0], [1.0]) == 0.0
    end

    test "zero-magnitude vector returns 0.0" do
      assert AI.Embeddings.cosine_similarity([0.0, 0.0], [1.0, 1.0]) == 0.0
    end
  end
end
