defmodule AI.Model.VeniceTest do
  @moduledoc """
  Locks in the Venice profile catalog.

  Profile factories now map to multiple Venice-native models with
  different roles. Each test pins the wire-level model id and reasoning
  level per profile so a model swap or reasoning-level retune surfaces
  in exactly one place. Context windows are validated where they vary
  meaningfully across factories (qwen-3-6-plus and deepseek-v4-flash
  share 1M, kimi-k2-6 is 256K, mercury-2 is 128K).
  """

  use Fnord.TestCase, async: false
  alias AI.Model.Venice

  describe "named profiles" do
    test "smarter -> kimi-k2-6 with reasoning :high" do
      m = Venice.smarter()
      assert m.model == "kimi-k2-6"
      assert m.context == 256_000
      assert m.reasoning == :high
      assert m.supports_reasoning
      assert m.supports_web_search
    end

    test "smart -> qwen-3-6-plus with reasoning :low" do
      m = Venice.smart()
      assert m.model == "qwen-3-6-plus"
      assert m.context == 1_000_000
      assert m.reasoning == :low
    end

    test "balanced -> qwen-3-6-plus with reasoning :none" do
      m = Venice.balanced()
      assert m.model == "qwen-3-6-plus"
      assert m.context == 1_000_000
      assert m.reasoning == :none
    end

    test "fast -> mercury-2 with reasoning :low" do
      m = Venice.fast()
      assert m.model == "mercury-2"
      assert m.context == 128_000
      assert m.reasoning == :low
    end

    test "web_search -> mercury-2 with reasoning :low" do
      m = Venice.web_search()
      assert m.model == "mercury-2"
      assert m.context == 128_000
      assert m.reasoning == :low
      assert m.supports_web_search
    end

    test "coding -> kimi-k2-6 with reasoning :none" do
      m = Venice.coding()
      assert m.model == "kimi-k2-6"
      assert m.context == 256_000
      assert m.reasoning == :none
    end
  end

  describe "large_context/1 (consolidated on deepseek-v4-flash)" do
    test "all tiers route through deepseek-v4-flash, differing by reasoning level" do
      smart = Venice.large_context(:smart)
      balanced = Venice.large_context(:balanced)
      fast = Venice.large_context(:fast)

      for m <- [smart, balanced, fast] do
        assert m.model == "deepseek-v4-flash"
        assert m.context == 1_000_000
        assert m.supports_reasoning
        assert m.supports_web_search
      end

      assert smart.reasoning == :high
      assert balanced.reasoning == :medium
      assert fast.reasoning == :low
    end
  end

  test "every profile carries the expected model id and capability flags" do
    # Tuple list pins per-profile expectations so a future model swap
    # has to update exactly one row here. Capability flags are checked
    # in the sweep below to catch a "forgot supports_reasoning on a new
    # factory" regression in a single place.
    profiles = [
      {Venice.smarter(), "kimi-k2-6", 256_000},
      {Venice.smart(), "qwen-3-6-plus", 1_000_000},
      {Venice.balanced(), "qwen-3-6-plus", 1_000_000},
      {Venice.fast(), "mercury-2", 128_000},
      {Venice.web_search(), "mercury-2", 128_000},
      {Venice.coding(), "kimi-k2-6", 256_000},
      {Venice.large_context(:smart), "deepseek-v4-flash", 1_000_000},
      {Venice.large_context(:balanced), "deepseek-v4-flash", 1_000_000},
      {Venice.large_context(:fast), "deepseek-v4-flash", 1_000_000}
    ]

    for {m, expected_model_id, expected_context} <- profiles do
      assert m.model == expected_model_id
      assert m.context == expected_context
      assert m.supports_reasoning, "#{m.model} should support reasoning"
      assert m.supports_web_search, "#{m.model} should support web search"
    end
  end
end
