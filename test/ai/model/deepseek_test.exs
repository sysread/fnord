defmodule AI.Model.DeepSeekTest do
  @moduledoc """
  Locks in the DeepSeek profile catalog.

  Single hosted model in fnord's catalog: `deepseek-v4-flash` (1M
  context, reasoning-capable, no native web search). Named profiles
  differ only by reasoning level.
  """

  use Fnord.TestCase, async: false
  alias AI.Model.DeepSeek

  describe "named profiles" do
    test "smarter -> deepseek-v4-flash reasoning :high" do
      m = DeepSeek.smarter()
      assert m.model == "deepseek-v4-flash"
      assert m.context == 1_000_000
      assert m.reasoning == :high
      assert m.supports_reasoning
      refute m.supports_web_search
    end

    test "smart -> reasoning :medium" do
      assert DeepSeek.smart().reasoning == :medium
    end

    test "balanced -> reasoning :low" do
      assert DeepSeek.balanced().reasoning == :low
    end

    test "fast -> reasoning :none" do
      assert DeepSeek.fast().reasoning == :none
    end

    test "web_search -> reasoning :none (provider has no native web search)" do
      m = DeepSeek.web_search()
      assert m.reasoning == :none
      refute m.supports_web_search
    end

    test "coding -> reasoning :low" do
      assert DeepSeek.coding().reasoning == :low
    end

    test "large_context tiers vary reasoning level" do
      assert DeepSeek.large_context(:smart).reasoning == :high
      assert DeepSeek.large_context(:balanced).reasoning == :medium
      assert DeepSeek.large_context(:fast).reasoning == :none
    end
  end

  test "every profile routes through deepseek-v4-flash with expected capability flags" do
    profiles = [
      DeepSeek.smarter(),
      DeepSeek.smart(),
      DeepSeek.balanced(),
      DeepSeek.fast(),
      DeepSeek.web_search(),
      DeepSeek.coding(),
      DeepSeek.large_context(:smart),
      DeepSeek.large_context(:balanced),
      DeepSeek.large_context(:fast)
    ]

    for m <- profiles do
      assert m.model == "deepseek-v4-flash"
      assert m.context == 1_000_000
      assert m.supports_reasoning, "#{m.model} should declare reasoning support"
      refute m.supports_web_search, "#{m.model} should not declare web search support"
    end
  end
end
