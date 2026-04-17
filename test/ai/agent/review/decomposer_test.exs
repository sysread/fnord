defmodule AI.Agent.Review.DecomposerTest do
  use Fnord.TestCase, async: false

  alias AI.Agent.Review.Decomposer
  alias AI.Agent.Composite

  test "init seeds the estimate step only" do
    {:ok, state} = Decomposer.init(%{agent: %{name: :review}, scope: "review this change"})

    assert [%{name: :estimate}, %{name: :constraints}] = state.steps
  end

  test "on_step_start labels the new constraints step" do
    state = %Composite{agent: %{name: "review"}}

    Decomposer.on_step_start(%{name: :constraints}, state)
    assert_receive {:ui_report, received_name, "Extracting constraints and contract surface"}
    assert received_name in ["review", :review]
  end

  test "on_step_complete stores parsed constraints in composite state" do
    state = %Composite{
      agent: %{name: :review},
      response:
        ~s({"constraints":[{"id":"C1","type":"contract","scope":"foo","confidence":0.9,"statement":"foo must stay stable","citations":[{"source_kind":"pr_description","reference":"desc:1"}]}]})
    }

    updated = Decomposer.on_step_complete(%{name: :constraints}, %{state | internal: %{}})

    assert {:ok, %{constraints: [%{id: "C1", statement: "foo must stay stable"}]}} =
             Composite.get_state(updated, :constraints)
  end

  test "small scope renders constraints when provided" do
    estimate = %{
      git_range: "abc123..HEAD",
      diff_stat: " lib/foo.ex | 2 ++",
      exclude_paths: [],
      exclude_reasoning: "",
      constraints: [
        %{
          id: "C1",
          type: "contract",
          scope: "lib/foo.ex",
          confidence: 0.8,
          statement: "callers must keep passing a map",
          citations: [%{source_kind: "pr_description", reference: "desc:2"}]
        }
      ]
    }

    scope = :erlang.apply(Decomposer, :build_small_scope, ["review scope", estimate])

    assert String.contains?(scope, "## Constraints")
    assert String.contains?(scope, "C1")
    assert String.contains?(scope, "callers must keep passing a map")
  end

  test "decomposer responds to constraints step in the pipeline callbacks" do
    assert function_exported?(Decomposer, :on_step_start, 2)
    assert function_exported?(Decomposer, :on_step_complete, 2)
    assert function_exported?(Decomposer, :get_next_steps, 2)
  end
end
