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
end
