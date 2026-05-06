defmodule AI.Model.VeniceTest do
  @moduledoc """
  Locks in the Venice profile catalog. The model identifiers come from
  `scratch/venice-models.md` and changing them is a meaningful behavior
  change worth catching in CI.
  """

  use ExUnit.Case
  alias AI.Model.Venice

  test "smarter -> kimi-k2-6, 256k context, both capabilities on" do
    m = Venice.smarter()
    assert m.model == "kimi-k2-6"
    assert m.context == 256_000
    assert m.supports_reasoning
    assert m.supports_web_search
  end

  test "smart -> zai-org-glm-5-1, 200k context" do
    m = Venice.smart()
    assert m.model == "zai-org-glm-5-1"
    assert m.context == 200_000
  end

  test "balanced -> zai-org-glm-5, 256k context" do
    m = Venice.balanced()
    assert m.model == "zai-org-glm-5"
    assert m.context == 256_000
  end

  test "fast -> zai-org-glm-4.7, 198k context" do
    m = Venice.fast()
    assert m.model == "zai-org-glm-4.7"
    assert m.context == 198_000
  end

  test "web_search -> qwen3-5-35b-a3b, 256k context, web search supported" do
    m = Venice.web_search()
    assert m.model == "qwen3-5-35b-a3b"
    assert m.context == 256_000
    assert m.supports_web_search
  end

  test "large_context tiers all map to grok-41-fast (1M context)" do
    for tier <- [:smart, :balanced, :fast] do
      m = Venice.large_context(tier)
      assert m.model == "grok-41-fast"
      assert m.context == 1_000_000
    end
  end

  test "all current profiles support reasoning and web search" do
    profiles = [
      Venice.smarter(),
      Venice.smart(),
      Venice.balanced(),
      Venice.fast(),
      Venice.web_search(),
      Venice.large_context(:smart)
    ]

    for m <- profiles do
      assert m.supports_reasoning, "#{m.model} should support reasoning"
      assert m.supports_web_search, "#{m.model} should support web search"
    end
  end
end
