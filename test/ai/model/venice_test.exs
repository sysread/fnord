defmodule AI.Model.VeniceTest do
  @moduledoc """
  Locks in the Venice profile catalog.

  The catalog is partially consolidated for end-to-end provider
  testing: `smart`, `smarter`, `balanced`, `fast`, `web_search`, and
  `coding` all currently route through `qwen-3-6-plus`; `large_context`
  (all three tiers) routes through `deepseek-v4-flash`. Restoration of
  the original per-profile catalog (kimi-k2-6 / grok-41-fast /
  qwen3-5-35b-a3b) is gated on continuing real-API validation. Until
  then these tests verify the contract shape - profile factories
  return properly-populated `AI.Model.t` structs with capability flags
  set - rather than locking specific model identities for every
  profile.
  """

  use Fnord.TestCase, async: false
  alias AI.Model.Venice

  @test_model "qwen-3-6-plus"
  @large_context_model "deepseek-v4-flash"
  @context 1_000_000

  describe "named profiles (consolidated on qwen-3-6-plus)" do
    test "smarter -> high reasoning" do
      m = Venice.smarter()
      assert m.model == @test_model
      assert m.context == @context
      assert m.reasoning == :high
      assert m.supports_reasoning
      assert m.supports_web_search
    end

    test "smart -> medium reasoning" do
      m = Venice.smart()
      assert m.model == @test_model
      assert m.reasoning == :medium
    end

    test "balanced -> low reasoning" do
      m = Venice.balanced()
      assert m.model == @test_model
      assert m.reasoning == :low
    end

    test "fast -> no reasoning" do
      m = Venice.fast()
      assert m.model == @test_model
      assert m.reasoning == :none
    end

    test "web_search -> medium reasoning" do
      m = Venice.web_search()
      assert m.model == @test_model
      assert m.reasoning == :medium
      assert m.supports_web_search
    end

    test "coding -> medium reasoning" do
      m = Venice.coding()
      assert m.model == @test_model
      assert m.reasoning == :medium
    end
  end

  describe "large_context/1 (consolidated on deepseek-v4-flash)" do
    test "all tiers route through deepseek-v4-flash, differing by reasoning level" do
      smart = Venice.large_context(:smart)
      balanced = Venice.large_context(:balanced)
      fast = Venice.large_context(:fast)

      for m <- [smart, balanced, fast] do
        assert m.model == @large_context_model
        assert m.context == @context
        assert m.supports_reasoning
        assert m.supports_web_search
      end

      assert smart.reasoning == :high
      assert balanced.reasoning == :medium
      assert fast.reasoning == :low
    end
  end

  test "every profile carries the expected capability flags" do
    # Each tuple is {profile_fn_result, expected_wire_model_id}. The
    # two-model split (qwen-3-6-plus for everything except
    # large_context, deepseek-v4-flash for large_context) is asserted
    # explicitly so a future profile renaming or model swap surfaces
    # here.
    profiles = [
      {Venice.smarter(), @test_model},
      {Venice.smart(), @test_model},
      {Venice.balanced(), @test_model},
      {Venice.fast(), @test_model},
      {Venice.web_search(), @test_model},
      {Venice.coding(), @test_model},
      {Venice.large_context(:smart), @large_context_model},
      {Venice.large_context(:balanced), @large_context_model},
      {Venice.large_context(:fast), @large_context_model}
    ]

    for {m, expected_model_id} <- profiles do
      assert m.model == expected_model_id
      assert m.context == @context
      assert m.supports_reasoning, "#{m.model} should support reasoning"
      assert m.supports_web_search, "#{m.model} should support web search"
    end
  end
end
