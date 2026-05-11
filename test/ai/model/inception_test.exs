defmodule AI.Model.InceptionTest do
  @moduledoc """
  Locks in the Inception Labs profile catalog.

  Inception ships exactly one hosted model (`mercury-2`, 128K context),
  but the named profile factories vary the reasoning level per role.
  Capability flags are uniform across profiles - `supports_reasoning`
  is true (mercury-2 accepts the reasoning_effort field),
  `supports_web_search` is false (Inception has no native web search).
  """

  use Fnord.TestCase, async: false
  alias AI.Model.Inception

  describe "named profiles (per-role reasoning level on mercury-2)" do
    test "smarter -> mercury-2 reasoning :high" do
      m = Inception.smarter()
      assert m.model == "mercury-2"
      assert m.context == 128_000
      assert m.reasoning == :high
    end

    test "smart -> mercury-2 reasoning :medium" do
      assert Inception.smart().reasoning == :medium
    end

    test "balanced -> mercury-2 reasoning :low" do
      assert Inception.balanced().reasoning == :low
    end

    test "fast -> mercury-2 reasoning :none" do
      assert Inception.fast().reasoning == :none
    end

    test "web_search -> mercury-2 reasoning :none" do
      assert Inception.web_search().reasoning == :none
    end

    test "coding -> mercury-2 reasoning :low" do
      assert Inception.coding().reasoning == :low
    end

    test "large_context tiers route through mercury-2" do
      for tier <- [:smart, :balanced, :fast] do
        m = Inception.large_context(tier)
        assert m.model == "mercury-2"
        assert m.context == 128_000
      end
    end
  end

  test "every profile carries the expected capability flags" do
    profiles = [
      Inception.smarter(),
      Inception.smart(),
      Inception.balanced(),
      Inception.fast(),
      Inception.web_search(),
      Inception.coding(),
      Inception.large_context(:smart),
      Inception.large_context(:balanced),
      Inception.large_context(:fast)
    ]

    for m <- profiles do
      assert m.model == "mercury-2"
      assert m.context == 128_000
      assert m.supports_reasoning, "#{m.model} should declare reasoning support"
      refute m.supports_web_search, "#{m.model} should not declare web search support"
    end
  end
end
