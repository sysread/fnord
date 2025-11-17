defmodule AI.MemoryTest do
  use Fnord.TestCase, async: false

  describe "new/1" do
    test "creates memory with defaults" do
      memory = AI.Memory.new(%{label: "test", response_template: "Test response"})

      assert memory.label == "test"
      assert memory.response_template == "Test response"
      assert memory.scope == :global
      assert memory.weight == 1.0
      assert memory.children == []
      assert memory.pattern_tokens == %{}
      assert memory.fire_count == 0
      assert memory.success_count == 0
      refute is_nil(memory.id)
      refute is_nil(memory.slug)
      refute is_nil(memory.created_at)
    end

    test "accepts custom scope" do
      memory = AI.Memory.new(%{label: "test", response_template: "Test", scope: :project})
      assert memory.scope == :project
    end
  end

  describe "validate/1" do
    test "accepts valid memory" do
      memory = AI.Memory.new(%{label: "test", response_template: "Test response"})
      assert {:ok, ^memory} = AI.Memory.validate(memory)
    end

    test "rejects missing label" do
      memory = AI.Memory.new(%{label: nil, response_template: "Test"})
      assert {:error, "label is required"} = AI.Memory.validate(memory)

      memory = AI.Memory.new(%{label: "", response_template: "Test"})
      assert {:error, "label is required"} = AI.Memory.validate(memory)
    end

    test "rejects label too long" do
      long_label = String.duplicate("a", 51)
      memory = AI.Memory.new(%{label: long_label, response_template: "Test"})
      assert {:error, msg} = AI.Memory.validate(memory)
      assert msg =~ "label exceeds"
    end

    test "rejects missing response_template" do
      memory = AI.Memory.new(%{label: "test", response_template: nil})
      assert {:error, "response_template is required"} = AI.Memory.validate(memory)
    end

    test "rejects response_template too long" do
      long_response = String.duplicate("a", AI.Memory.max_label_chars() + 1)
      memory = AI.Memory.new(%{label: "test", response_template: long_response})
      assert {:error, msg} = AI.Memory.validate(memory)
      assert msg =~ "response_template exceeds"
      assert msg =~ "keep thoughts brief"
    end

    test "rejects invalid scope" do
      memory = AI.Memory.new(%{label: "test", response_template: "Test", scope: :invalid})
      assert {:error, "scope must be :global or :project"} = AI.Memory.validate(memory)
    end
  end

  describe "generate_slug/1" do
    test "converts to lowercase and joins with dashes" do
      assert AI.Memory.generate_slug("User Prefers Concise Examples") ==
               "user-prefer-concis-exampl"
    end

    test "removes articles" do
      assert AI.Memory.generate_slug("The Quick Brown Fox") == "quick-brown-fox"
      assert AI.Memory.generate_slug("A Simple Test") == "simpl-test"
      assert AI.Memory.generate_slug("An Example") == "exampl"
    end

    test "stems tokens" do
      assert AI.Memory.generate_slug("running quickly") == "run-quick"
      assert AI.Memory.generate_slug("testing examples") == "test-exampl"
    end

    test "truncates to 50 characters" do
      long_label = "This is a very long label that will definitely exceed fifty characters"
      slug = AI.Memory.generate_slug(long_label)
      assert String.length(slug) <= 50
    end

    test "handles special characters" do
      assert AI.Memory.generate_slug("test/with.special-chars!") == "test-with-special-char"
    end
  end

  describe "normalize_to_tokens/1" do
    test "lowercases text" do
      tokens = AI.Memory.normalize_to_tokens("HELLO WORLD")
      assert Map.has_key?(tokens, "hello")
      assert Map.has_key?(tokens, "world")
    end

    test "stems tokens" do
      tokens = AI.Memory.normalize_to_tokens("running quickly")
      assert Map.has_key?(tokens, "run")
      assert Map.has_key?(tokens, "quick")
      refute Map.has_key?(tokens, "running")
      refute Map.has_key?(tokens, "quickly")
    end

    test "removes stopwords AFTER stemming" do
      # These stopwords should be removed after stemming
      tokens = AI.Memory.normalize_to_tokens("the cat is on the mat")
      refute Map.has_key?(tokens, "the")
      refute Map.has_key?(tokens, "is")
      refute Map.has_key?(tokens, "on")
      assert Map.has_key?(tokens, "cat")
      assert Map.has_key?(tokens, "mat")
    end

    test "counts token frequencies" do
      tokens = AI.Memory.normalize_to_tokens("cat dog cat bird cat")
      assert tokens["cat"] == 3
      assert tokens["dog"] == 1
      assert tokens["bird"] == 1
    end

    test "handles empty string" do
      tokens = AI.Memory.normalize_to_tokens("")
      assert tokens == %{}
    end
  end

  describe "merge_tokens/2" do
    test "merges two token maps by adding frequencies" do
      acc = %{"cat" => 2, "dog" => 1}
      new = %{"cat" => 1, "bird" => 1}
      merged = AI.Memory.merge_tokens(acc, new)

      assert merged["cat"] == 3
      assert merged["dog"] == 1
      assert merged["bird"] == 1
    end

    test "handles empty accumulator" do
      merged = AI.Memory.merge_tokens(%{}, %{"cat" => 1})
      assert merged == %{"cat" => 1}
    end

    test "handles empty new tokens" do
      acc = %{"cat" => 2}
      merged = AI.Memory.merge_tokens(acc, %{})
      assert merged == acc
    end
  end

  describe "trim_to_top_k/2" do
    test "keeps top K tokens by frequency" do
      tokens = %{
        "very" => 10,
        "common" => 8,
        "word" => 6,
        "rare" => 2,
        "rarer" => 1
      }

      trimmed = AI.Memory.trim_to_top_k(tokens, 3)

      assert map_size(trimmed) == 3
      assert trimmed["very"] == 10
      assert trimmed["common"] == 8
      assert trimmed["word"] == 6
      refute Map.has_key?(trimmed, "rare")
      refute Map.has_key?(trimmed, "rarer")
    end

    test "keeps all tokens if K >= size" do
      tokens = %{"cat" => 1, "dog" => 2}
      trimmed = AI.Memory.trim_to_top_k(tokens, 10)
      assert trimmed == tokens
    end
  end

  describe "compute_match_probability/2" do
    test "returns 0 for empty pattern" do
      accumulated = %{"cat" => 1, "dog" => 1}
      assert AI.Memory.compute_match_probability(accumulated, %{}) == 0.0
    end

    test "returns 0 for empty accumulated" do
      pattern = %{"cat" => 1}
      assert AI.Memory.compute_match_probability(%{}, pattern) == 0.0
    end

    test "returns high probability for matching tokens" do
      accumulated = %{"cat" => 5, "dog" => 3, "bird" => 2}
      pattern = %{"cat" => 10, "dog" => 5}
      prob = AI.Memory.compute_match_probability(accumulated, pattern)

      assert prob > 0.0
      assert prob <= 1.0
    end

    test "returns low probability for non-matching tokens" do
      accumulated = %{"elephant" => 5, "giraffe" => 3}
      pattern = %{"cat" => 10, "dog" => 5}
      prob = AI.Memory.compute_match_probability(accumulated, pattern)

      # Should be low but non-zero due to Laplace smoothing
      assert prob > 0.0
      assert prob < 0.1
    end

    test "returns value between 0 and 1" do
      accumulated = %{"test" => 100, "word" => 50}
      pattern = %{"test" => 10, "other" => 5}
      prob = AI.Memory.compute_match_probability(accumulated, pattern)

      assert prob >= 0.0
      assert prob <= 1.0
    end
  end

  describe "compute_score/2" do
    test "multiplies probability by weight" do
      memory =
        AI.Memory.new(%{
          label: "test",
          response_template: "Test",
          pattern_tokens: %{"cat" => 10},
          weight: 2.0
        })

      accumulated = %{"cat" => 5}
      score = AI.Memory.compute_score(memory, accumulated)

      # Score should be > 0 and influenced by weight
      assert score > 0.0
    end

    test "clamps weight before scoring" do
      memory =
        AI.Memory.new(%{
          label: "test",
          response_template: "Test",
          pattern_tokens: %{"cat" => 10},
          # Will be clamped to 10.0
          weight: 100.0
        })

      accumulated = %{"cat" => 5}
      score = AI.Memory.compute_score(memory, accumulated)

      # Score should reflect clamped weight
      assert score > 0.0
      assert score <= 10.0
    end
  end

  describe "train/3" do
    test "updates pattern tokens with new input" do
      memory =
        AI.Memory.new(%{
          label: "test",
          response_template: "Test",
          pattern_tokens: %{"cat" => 1},
          weight: 1.0
        })

      trained = AI.Memory.train(memory, "cat dog", 0.5)

      # existing + new
      assert trained.pattern_tokens["cat"] == 2
      # new
      assert trained.pattern_tokens["dog"] == 1
      # 1.0 + 0.5
      assert trained.weight == 1.5
    end

    test "clamps weight after training" do
      memory =
        AI.Memory.new(%{
          label: "test",
          response_template: "Test",
          weight: 9.0
        })

      trained = AI.Memory.train(memory, "test", 5.0)
      # Clamped to max
      assert trained.weight == 10.0
    end

    test "can decrease weight" do
      memory =
        AI.Memory.new(%{
          label: "test",
          response_template: "Test",
          weight: 2.0
        })

      trained = AI.Memory.train(memory, "test", -1.0)
      assert trained.weight == 1.0
    end
  end

  describe "clamp_weight/1" do
    test "clamps to minimum" do
      assert AI.Memory.clamp_weight(0.05) == 0.1
      assert AI.Memory.clamp_weight(-1.0) == 0.1
    end

    test "clamps to maximum" do
      assert AI.Memory.clamp_weight(15.0) == 10.0
      assert AI.Memory.clamp_weight(100.0) == 10.0
    end

    test "leaves valid weights unchanged" do
      assert AI.Memory.clamp_weight(0.5) == 0.5
      assert AI.Memory.clamp_weight(5.0) == 5.0
      assert AI.Memory.clamp_weight(9.9) == 9.9
    end
  end
end
