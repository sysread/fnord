defmodule AI.Agent.Review.ReviewerTest do
  use Fnord.TestCase, async: false

  test "formulation prompt tells specialists about constraints sections" do
    prompt = AI.Agent.Review.Reviewer.__send__(:formulation_prompt)

    assert String.contains?(prompt, "## Constraints")
    assert String.contains?(prompt, "include which constraints a finding would violate")
  end

  test "aggregation prompt asks for constraint references in findings" do
    prompt = AI.Agent.Review.Reviewer.__send__(:aggregation_prompt)

    assert String.contains?(prompt, "violated constraint ids")
    assert String.contains?(prompt, "group final report output by constraints")
  end
end
