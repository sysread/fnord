defmodule AI.Agent.Review.DecomposerTest do
  use Fnord.TestCase, async: false

  alias AI.Agent.Review.Decomposer
  alias AI.Agent.Composite

  test "init seeds the estimate step only" do
    # `preflight: :skip` bypasses the git preflight; this test is about
    # step seeding, not about range resolution.
    {:ok, state} =
      Decomposer.init(%{
        agent: %{name: :review},
        scope: "review this change",
        preflight: :skip
      })

    assert [%{name: :estimate}, %{name: :constraints}] = state.steps
  end

  test "init hard-fails with actionable error when on main/master with no target" do
    # Without an explicit target (branch/pr/range) and when the current
    # checkout IS the default base, the preflight must return an error so
    # the user is told to name a target instead of silently reviewing
    # "nothing on main."
    project = mock_git_project("review-hardfail-project")
    git_config_user!(project)
    git_empty_commit!(project)

    assert {:error, msg} =
             Decomposer.init(%{agent: %{name: :review}, scope: "review"})

    assert msg =~ "you are on"
    assert msg =~ "Pass `branch:`"
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

  # Regression: get_next_steps/2 used to bind the raw constraints state
  # value (a %{constraints: [...]} wrapper map) straight into build_small_scope,
  # so render_constraints_section iterated the wrapper as key-value pairs
  # and blew up with BadMapError at `constraint.citations`. The small-scope
  # branch fans out to a reviewer + synthesis step; we assert the pipeline
  # returns cleanly with both steps present.
  test "get_next_steps for :constraints renders constraints without crashing" do
    state =
      %Composite{agent: %{name: :review}, request: "review scope", internal: %{}}
      |> Composite.put_state(:estimate, %{
        points: 2,
        git_range: "abc123..HEAD",
        diff_stat: " lib/foo.ex | 2 ++",
        exclude_paths: [],
        exclude_reasoning: ""
      })
      |> Composite.put_state(:constraints, %{
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
      })

    steps = Decomposer.get_next_steps(%{name: :constraints}, state)

    assert [%{name: :review_0}, %{name: :synthesize}] = steps
  end

  test "init with explicit range resolves end-to-end" do
    # Set up a project with two commits so HEAD~1..HEAD has a concrete
    # range to review. Exercises the happy path through resolve_target ->
    # resolve_range -> git.
    project = mock_git_project("review-range-project")
    git_config_user!(project)
    git_empty_commit!(project)
    git_empty_commit!(project)

    assert {:ok, state} =
             Decomposer.init(%{
               agent: %{name: :review},
               scope: "review",
               range: "HEAD~1..HEAD"
             })

    context_msg =
      Enum.find(state.messages, fn msg ->
        String.contains?(msg.content || "", "## Git context")
      end)

    assert context_msg, "expected a git-context message from the preflight"
    assert context_msg.content =~ "Resolved range:"
    assert context_msg.content =~ "explicit range"
    assert context_msg.content =~ "git diff --stat"
    assert context_msg.content =~ "git log --oneline"
  end
end
