defmodule AI.Model.OpenAITest do
  @moduledoc """
  Locks in the OpenAI profile catalog.

  Mirrors `test/ai/model/venice_test.exs` in shape so any future provider
  catalog can use the same pattern: assert wire-level model id, context,
  reasoning level, and capability flags on every named profile, then a
  catch-all sweep that every profile returns a well-formed `AI.Model.t`.

  The capability matrix is per-model rather than per-profile (the OpenAI
  catalog has several models that do not accept `reasoning_effort` or
  `web_search_options`), so the per-profile assertions check exactly the
  flags that family is expected to carry.
  """

  use Fnord.TestCase, async: false
  alias AI.Model.OpenAI

  describe "named profiles" do
    test "smarter -> gpt-5.5 with reasoning :low" do
      m = OpenAI.smarter()
      assert m.model == "gpt-5.5"
      assert m.context == 1_050_000
      assert m.reasoning == :low
      assert m.supports_reasoning
      refute m.supports_web_search
    end

    test "smart -> gpt-5.4 with reasoning :none" do
      m = OpenAI.smart()
      assert m.model == "gpt-5.4"
      assert m.reasoning == :none
      refute m.supports_reasoning
      refute m.supports_web_search
    end

    test "balanced -> gpt-5.4 with reasoning :none" do
      m = OpenAI.balanced()
      assert m.model == "gpt-5.4"
      assert m.reasoning == :none
      refute m.supports_reasoning
    end

    test "fast -> gpt-5.4-mini" do
      m = OpenAI.fast()
      assert m.model == "gpt-5.4-mini"
      assert m.context == 400_000
      refute m.supports_reasoning
    end

    test "web_search -> gpt-5-search-api with web search capability" do
      m = OpenAI.web_search()
      assert m.model == "gpt-5-search-api"
      assert m.supports_web_search
      refute m.supports_reasoning
    end

    test "coding aliases balanced (OpenAI has no coding-tuned model)" do
      # Documented in the moduledoc: OpenAI's catalog lacks a coding-
      # tuned variant in fnord's profile set, so `coding` falls through
      # to `balanced`. Venice overrides this aliasing because it ships
      # a real coding-tuned model. The test pins the alias so a future
      # change has to update this expectation explicitly.
      assert OpenAI.coding() == OpenAI.balanced()
    end
  end

  describe "large_context/1" do
    test ":smart -> gpt-4.1" do
      m = OpenAI.large_context(:smart)
      assert m.model == "gpt-4.1"
      assert m.context == 1_000_000
    end

    test ":balanced -> gpt-4.1-mini" do
      m = OpenAI.large_context(:balanced)
      assert m.model == "gpt-4.1-mini"
      assert m.context == 1_000_000
    end

    test ":fast -> gpt-4.1-nano" do
      m = OpenAI.large_context(:fast)
      assert m.model == "gpt-4.1-nano"
      assert m.context == 1_000_000
    end
  end

  test "every profile returns a well-formed AI.Model.t" do
    profiles = [
      OpenAI.smarter(),
      OpenAI.smart(),
      OpenAI.balanced(),
      OpenAI.fast(),
      OpenAI.web_search(),
      OpenAI.coding(),
      OpenAI.large_context(:smart),
      OpenAI.large_context(:balanced),
      OpenAI.large_context(:fast)
    ]

    for m <- profiles do
      assert is_binary(m.model) and m.model != ""
      assert is_integer(m.context) and m.context > 0
      assert m.reasoning in [:none, :minimal, :low, :medium, :high]
      assert is_boolean(m.supports_reasoning)
      assert is_boolean(m.supports_web_search)
    end
  end
end
