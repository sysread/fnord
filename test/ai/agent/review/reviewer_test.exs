defmodule AI.Agent.Review.ReviewerTest do
  use Fnord.TestCase, async: true

  test "formulation prompt tells specialists about constraints sections" do
    prompt = AI.Agent.Review.Reviewer.__send__(:formulation_prompt)

    assert String.contains?(prompt, "## Constraints")
    assert String.contains?(prompt, "include which constraints a finding would violate")
    assert String.contains?(prompt, "producer -> transform -> consumer chain")
    assert String.contains?(prompt, "authoritative source of truth")
  end

  test "aggregation prompt asks for constraint references in findings" do
    prompt = AI.Agent.Review.Reviewer.__send__(:aggregation_prompt)

    assert String.contains?(prompt, "violated constraint ids")
    assert String.contains?(prompt, "group final report output by constraints")
    assert String.contains?(prompt, "manually fabricating invalid")

    assert String.contains?(
             prompt,
             "default for plausible claims that lack a proven trigger path"
           )
  end

  test "specialist response format requires reachability and provenance proof fields" do
    item =
      get_in(AI.Agent.Review.Reviewer.specialist_response_format(), [
        :json_schema,
        :schema,
        :properties,
        :findings,
        :items
      ])

    required = Map.fetch!(item, :required)
    properties = Map.fetch!(item, :properties)

    assert "trigger_scenario" in required
    assert "reachability_analysis" in required
    assert "source_of_truth" in required
    assert "producer_chain" in required

    assert Map.has_key?(properties, :trigger_scenario)
    assert Map.has_key?(properties, :reachability_analysis)
    assert Map.has_key?(properties, :source_of_truth)
    assert Map.has_key?(properties, :producer_chain)
  end
end
