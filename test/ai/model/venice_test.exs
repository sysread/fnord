defmodule AI.Model.VeniceTest do
  @moduledoc """
  Locks in the Venice profile catalog.

  Profile factories map to several Venice-native models with different
  roles. Each test pins the wire-level model id, context window,
  reasoning level, and capability flags per profile so any swap or
  retune surfaces in exactly one place. The catalog is in flux while
  per-profile picks are tuned against the live API; the impl block in
  `lib/ai/model/venice.ex` is authoritative.
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

    test "smart -> z-ai-glm-5-turbo with reasoning :low" do
      m = Venice.smart()
      assert m.model == "z-ai-glm-5-turbo"
      assert m.context == 200_000
      assert m.reasoning == :low
      assert m.supports_reasoning
    end

    test "balanced -> z-ai-glm-5-turbo with reasoning :none" do
      m = Venice.balanced()
      assert m.model == "z-ai-glm-5-turbo"
      assert m.context == 200_000
      assert m.reasoning == :none
      assert m.supports_reasoning
    end

    test "fast -> google-gemma-3-27b-it, non-reasoning" do
      m = Venice.fast()
      assert m.model == "google-gemma-3-27b-it"
      assert m.context == 198_000
      assert m.reasoning == :none
      refute m.supports_reasoning
      assert m.supports_web_search
    end

    test "web_search -> google-gemma-3-27b-it, non-reasoning, web-search-capable" do
      m = Venice.web_search()
      assert m.model == "google-gemma-3-27b-it"
      assert m.context == 198_000
      assert m.reasoning == :none
      refute m.supports_reasoning
      assert m.supports_web_search
    end

    test "coding -> kimi-k2-6 with reasoning :none" do
      m = Venice.coding()
      assert m.model == "kimi-k2-6"
      assert m.context == 256_000
      assert m.reasoning == :none
      assert m.supports_reasoning
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
    # has to update exactly one row here. `supports_reasoning` is per-
    # row because not every Venice-native model reasons (the gemma
    # model in fast/web_search does not).
    profiles = [
      {Venice.smarter(), "kimi-k2-6", 256_000, true},
      {Venice.smart(), "z-ai-glm-5-turbo", 200_000, true},
      {Venice.balanced(), "z-ai-glm-5-turbo", 200_000, true},
      {Venice.fast(), "google-gemma-3-27b-it", 198_000, false},
      {Venice.web_search(), "google-gemma-3-27b-it", 198_000, false},
      {Venice.coding(), "kimi-k2-6", 256_000, true},
      {Venice.large_context(:smart), "deepseek-v4-flash", 1_000_000, true},
      {Venice.large_context(:balanced), "deepseek-v4-flash", 1_000_000, true},
      {Venice.large_context(:fast), "deepseek-v4-flash", 1_000_000, true}
    ]

    for {m, expected_model_id, expected_context, expected_supports_reasoning} <- profiles do
      assert m.model == expected_model_id
      assert m.context == expected_context
      assert m.supports_reasoning == expected_supports_reasoning,
             "#{m.model} supports_reasoning expected #{expected_supports_reasoning}"

      assert m.supports_web_search, "#{m.model} should support web search"
    end
  end
end
