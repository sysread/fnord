defmodule AI.Model.VeniceTest do
  @moduledoc """
  Locks in the Venice profile catalog.

  The catalog is currently consolidated on a single model (`grok-4-20`)
  for end-to-end provider testing. Per-profile model selection will
  return once the mechanical interactions between provider modules are
  validated against the live API. Until then, these tests verify the
  contract shape - all profile factories return a properly-populated
  `AI.Model.t` with capability flags set, and the reasoning level is
  the only thing distinguishing tiers.
  """

  use ExUnit.Case
  alias AI.Model.Venice

  @model "grok-4-20"
  @context 2_000_000

  describe "named profiles" do
    test "smarter -> high reasoning" do
      m = Venice.smarter()
      assert m.model == @model
      assert m.context == @context
      assert m.reasoning == :high
      assert m.supports_reasoning
      assert m.supports_web_search
    end

    test "smart -> medium reasoning" do
      assert Venice.smart().reasoning == :medium
    end

    test "balanced -> low reasoning" do
      assert Venice.balanced().reasoning == :low
    end

    test "fast -> no reasoning" do
      assert Venice.fast().reasoning == :none
    end

    test "web_search -> medium reasoning" do
      m = Venice.web_search()
      assert m.reasoning == :medium
      assert m.supports_web_search
    end

    test "coding -> medium reasoning" do
      assert Venice.coding().reasoning == :medium
    end
  end

  describe "large_context/1" do
    test "tiers differ only by reasoning level" do
      smart = Venice.large_context(:smart)
      balanced = Venice.large_context(:balanced)
      fast = Venice.large_context(:fast)

      for m <- [smart, balanced, fast] do
        assert m.model == @model
        assert m.context == @context
      end

      assert smart.reasoning == :high
      assert balanced.reasoning == :medium
      assert fast.reasoning == :low
    end
  end

  test "every profile carries capability flags and the consolidated model" do
    profiles = [
      Venice.smarter(),
      Venice.smart(),
      Venice.balanced(),
      Venice.fast(),
      Venice.web_search(),
      Venice.coding(),
      Venice.large_context(:smart),
      Venice.large_context(:balanced),
      Venice.large_context(:fast)
    ]

    for m <- profiles do
      assert m.model == @model
      assert m.context == @context
      assert m.supports_reasoning, "#{m.model} should support reasoning"
      assert m.supports_web_search, "#{m.model} should support web search"
    end
  end
end
