defmodule AI.Agent.Review.ReviewerTest do
  use Fnord.TestCase, async: false

  test "formulate prompt tells specialists about constraints sections" do
    # Formulation runs as :research then :formulate. The constraints
    # guidance lives in the :formulate prompt since that's the step
    # that actually writes specialist prompts.
    prompt = AI.Agent.Review.Reviewer.__send__(:formulate_prompt)

    assert String.contains?(prompt, "## Constraints")
    assert String.contains?(prompt, "include which constraints a finding would violate")
  end

  test "research prompt instructs the model not to emit JSON" do
    prompt = AI.Agent.Review.Reviewer.__send__(:research_prompt)

    assert String.contains?(prompt, "research-only")
    assert String.contains?(prompt, "Do NOT emit JSON")
  end

  test "aggregation prompt asks for constraint references in findings" do
    prompt = AI.Agent.Review.Reviewer.__send__(:aggregation_prompt)

    assert String.contains?(prompt, "violated constraint ids")
    assert String.contains?(prompt, "group final report output by constraints")
  end
end
