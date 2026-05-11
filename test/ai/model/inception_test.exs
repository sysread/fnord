defmodule AI.Model.InceptionTest do
  @moduledoc """
  Locks in the Inception Labs profile catalog.

  Inception ships exactly one hosted model (`mercury-2`, 128K context),
  so every named profile resolves to the same factory. This test pins
  that contract: any profile factory addition that diverges from
  `mercury-2` should update both the impl and this test.
  """

  use Fnord.TestCase, async: false
  alias AI.Model.Inception

  test "every named profile resolves to mercury-2 with non-reasoning, non-search capability flags" do
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
      assert m.reasoning == :none
      refute m.supports_reasoning, "#{m.model} should not declare reasoning support"
      refute m.supports_web_search, "#{m.model} should not declare web search support"
    end
  end
end
