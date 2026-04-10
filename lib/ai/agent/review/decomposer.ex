defmodule AI.Agent.Review.Decomposer do
  @moduledoc """
  Triage agent for code reviews. Estimates change complexity, partitions large
  changes into right-sized review units, fans out scoped Reviewers in parallel,
  optionally runs an integration review for cross-component seams, and
  synthesizes a deduplicated final report.

  Sits between the `reviewer_tool` and `AI.Agent.Review.Reviewer`. Small changes
  (< 3 scrum points) pass through to a single Reviewer with full scope. Larger
  changes are decomposed so each Reviewer sees only a focused subset of files
  and concerns.

  ## Pipeline

  1. **Estimate** - read the diff, estimate scrum points (1-13), identify files
     to exclude from review (vendored, generated, lockfiles).
  2. **Partition** (>= 3 points) - split into ~3-point review units, each
     described as a self-contained briefing string for a scoped Reviewer.
  3. **Fan-out** - delegate to N scoped Reviewers (and an integration reviewer
     for >= 5 points), all running in parallel.
  4. **Synthesize** - deduplicate findings across review units, merge findings
     with the same root cause, produce a final severity-grouped report.

  Steps 2-4 are injected dynamically via `get_next_steps/2` based on the
  estimate result. This is the first composite agent to use dynamic step
  generation.
  """

  @behaviour AI.Agent
  @behaviour AI.Agent.Composite

  require Logger

  alias AI.Agent.Composite

  @model AI.Model.smart()

  # Pre-registered step name atoms for scoped reviewers. Using a fixed pool
  # avoids dynamic atom creation from LLM-controlled partition counts.
  @reviewer_step_names Enum.map(0..12, &:"review_#{&1}")

  # ---------------------------------------------------------------------------
  # Prompts
  # ---------------------------------------------------------------------------

  @system_prompt """
  You are a review decomposer. Your job is to triage a code change, assess its
  complexity, and - for larger changes - partition it into focused review units
  that can be reviewed independently.

  You are a STATIC ANALYSIS agent. You review code by reading it.
  Do NOT run tests, linters, compilers, or any build commands.
  Do NOT execute the code under review.
  """

  @estimate_prompt """
  Read the diff for the specified scope and produce a complexity estimate.

  ## Process

  1. Run `git diff --stat` on the specified range to see the shape of the change.
  2. Read the diffs for each changed file to understand what was modified.
  3. Infer design intent from commit messages (`git log --oneline <range>`) and
     the code itself.

  ## Estimation

  Estimate the review effort in scrum points (1-13 scale):
  - **1**: Trivial - typo fix, config tweak, single-line change.
  - **2**: Small - isolated change to one module, no new contracts.
  - **3**: Medium - touches 2-3 modules, or adds a new public interface.
  - **5**: Large - new feature with multiple integration points, or significant
    refactor of existing contracts.
  - **8**: Very large - cross-cutting change affecting many modules, new
    subsystem, or complex state management changes.
  - **13**: Massive - architectural change, new framework/infrastructure, or
    changes that touch nearly everything.

  Points reflect *review complexity*, not implementation effort. A 200-line diff
  in a critical state machine scores higher than 200 lines of a standalone module.

  ## Exclusions

  Identify files that should be excluded from review:
  - Vendored dependencies (e.g., `vendor/`, `deps/`)
  - Generated files (e.g., migrations with only timestamps, lockfiles)
  - Assets that aren't meaningfully reviewable (e.g., compiled JS, images)
  - Files that are gitignored but somehow appear in the diff

  ## Output

  Produce a JSON object with your estimate. Include the exact git range you used
  (e.g., "main...skills") and the full `git diff --stat` output so downstream
  reviewers don't have to re-fetch them.
  """

  @partition_prompt """
  Based on your complexity estimate and understanding of the change, partition it
  into review units of approximately 3 scrum points each.

  ## Rules

  1. Each review unit must be a self-contained briefing string that a Reviewer
     agent can act on independently.
  2. A briefing MUST include:
     - **The git range** to use for all git commands (from your estimate)
     - **The diff stat** for this unit's files (extracted from your full diff stat)
     - The list of files in this unit's scope
     - A summary of what the change does in those files
     - Focus areas and specific concerns
     - Explicit scope boundaries ("your scope is X; do NOT review Y")
     - Any excluded files that apply to this unit
  3. Downstream reviewers will use the git range and diff stat you provide
     instead of re-running git commands. Make sure they are accurate.
  4. Group files by logical component or feature, not by directory.
  5. Prefer slightly larger units over splitting tightly coupled files across units.
  6. The number of units must be consistent with your point estimate -
     you cannot create 4 units for a 3-point change.

  ## Output

  Produce a JSON object with a `review_units` array. Each element in the array
  is ONE review unit as a single string. You MUST produce at least 2 separate
  array elements - do NOT concatenate multiple units into one string.
  """

  @synthesis_prompt """
  You have received reports from multiple scoped reviewers. Your job is to produce
  a single, coherent final report.

  ## Process

  1. **Deduplicate**: The same issue may be flagged by multiple reviewers when
     it spans a component boundary. Merge these into a single finding.
  2. **Root-cause merge**: Multiple findings may stem from the same underlying
     issue (e.g., a contract mismatch causes errors in 3 call sites). Group
     these under the root cause.
  3. **Severity calibration**: Adjust severity based on the full picture. An
     issue that seemed MEDIUM in isolation may be HIGH when you see it affects
     multiple components.
  4. **Coverage check**: Note any files or areas that were not covered by any
     reviewer.

  ## Report format

  ### Scope
  - Branch/range reviewed
  - Estimated complexity (scrum points) and decomposition rationale

  ### Findings

  Group by severity (BLOCKING > HIGH > MEDIUM > LOW). For each:
  1. **Severity** and **category**
  2. **Source**: which reviewer(s) found it
  3. **Location**: file:line
  4. **Finding**: what the problem is
  5. **Evidence**: quoted code or traced path
  6. **Provenance**: branch-introduced or pre-existing

  ### Coverage gaps
  Files or areas not covered by any reviewer.
  """

  # ---------------------------------------------------------------------------
  # Integration review briefing template. Interpolated with boundary details
  # from the partition output.
  # ---------------------------------------------------------------------------

  @integration_briefing_template """
  You are reviewing the INTEGRATION SEAMS of a multi-component change.

  Component internals have been reviewed separately by other reviewers.
  Do NOT duplicate their work. Focus ONLY on:

  1. **Cross-component contracts** - do the interfaces between components match?
     Are types, error shapes, and assumptions consistent across boundaries?
  2. **Boundary correctness** - are there race conditions, ordering dependencies,
     or shared state issues at component boundaries?
  3. **Top-level coherence** - does the overall change make sense as a unit?
     Does the public API / user-facing behavior reflect the intended design?

  ## Git range

  Use `GIT_RANGE` for all git commands (diff, log, show, etc.).

  ## Review units (reviewed separately)

  REVIEW_UNITS_SUMMARY

  ## Excluded files

  EXCLUDE_PATHS

  ## Scope

  ORIGINAL_SCOPE
  """

  # ---------------------------------------------------------------------------
  # Response formats
  # ---------------------------------------------------------------------------

  @estimate_format %{
    type: "json_schema",
    json_schema: %{
      name: "review_estimate",
      schema: %{
        type: "object",
        required: [
          "points",
          "reasoning",
          "git_range",
          "diff_stat",
          "exclude_paths",
          "exclude_reasoning"
        ],
        additionalProperties: false,
        properties: %{
          points: %{
            type: "integer",
            minimum: 1,
            maximum: 13,
            description: "Scrum point estimate for review complexity"
          },
          reasoning: %{
            type: "string",
            description:
              "Justification for the point estimate - integration points, risk areas, complexity factors"
          },
          git_range: %{
            type: "string",
            description:
              "The exact git range used for diffing (e.g., 'main...skills', 'HEAD~3..HEAD')"
          },
          diff_stat: %{
            type: "string",
            description: "Full output of `git diff --stat` for the range"
          },
          exclude_paths: %{
            type: "array",
            items: %{type: "string"},
            description: "File paths or globs to exclude from review"
          },
          exclude_reasoning: %{
            type: "string",
            description: "Why these paths are excluded"
          }
        }
      }
    }
  }

  @partition_format %{
    type: "json_schema",
    json_schema: %{
      name: "review_partition",
      schema: %{
        type: "object",
        required: ["review_units"],
        additionalProperties: false,
        properties: %{
          review_units: %{
            type: "array",
            items: %{type: "string"},
            minItems: 2,
            description:
              "Self-contained briefing strings, one per review unit. Each is a complete scope description for a Reviewer agent."
          }
        }
      }
    }
  }

  # ---------------------------------------------------------------------------
  # AI.Agent behaviour
  # ---------------------------------------------------------------------------

  @impl AI.Agent
  def get_response(args) do
    Composite.run(__MODULE__, args)
  end

  # ---------------------------------------------------------------------------
  # AI.Agent.Composite behaviour
  # ---------------------------------------------------------------------------

  @impl AI.Agent.Composite
  def init(%{agent: agent, scope: scope}) do
    tools = AI.Tools.basic_tools()

    state = %Composite{
      agent: agent,
      model: @model,
      toolbox: tools,
      request: scope,
      response: nil,
      error: nil,
      messages: [
        AI.Util.system_msg(AI.Util.project_context()),
        AI.Util.system_msg(@system_prompt),
        AI.Util.user_msg(scope)
      ],
      internal: %{},
      steps: [
        Composite.completion(:estimate, @estimate_prompt,
          keep_prompt?: true,
          response_format: @estimate_format
        )
      ]
    }

    {:ok, state}
  end

  @impl AI.Agent.Composite
  def on_step_start(step, state) do
    label =
      case step.name do
        :estimate -> "Estimating review complexity"
        :partition -> "Decomposing into review units"
        :synthesize -> "Synthesizing review findings"
        :integration -> "Dispatching integration reviewer"
        name -> "Dispatching scoped reviewer #{name}"
      end

    UI.report_from(state.agent.name, label)
    state
  end

  # Both :estimate and :partition use json_schema response_format, so parse
  # failures indicate API-level problems, not schema drift. Halting is
  # intentional: get_next_steps pattern-matches on :estimate/:partition state,
  # so continuing without valid parsed data would crash downstream.
  @impl AI.Agent.Composite
  def on_step_complete(%{name: :estimate}, state) do
    case SafeJson.decode_lenient(state.response, keys: :atoms!) do
      {:ok,
       %{
         points: points,
         reasoning: _,
         git_range: _,
         diff_stat: _,
         exclude_paths: _,
         exclude_reasoning: _
       } =
           estimate}
      when is_integer(points) ->
        UI.report_from(state.agent.name, "Estimated complexity: #{points} points")
        Composite.put_state(state, :estimate, estimate)

      other ->
        Logger.warning("Decomposer: estimate parse failed: #{inspect(other)}")
        %{state | error: "Failed to parse estimate response"}
    end
  end

  def on_step_complete(%{name: :partition}, state) do
    case SafeJson.decode_lenient(state.response, keys: :atoms!) do
      {:ok, %{review_units: units}} when is_list(units) and length(units) >= 2 ->
        UI.report_from(
          state.agent.name,
          "Decomposed into #{length(units)} review units"
        )

        Composite.put_state(state, :partition, %{review_units: units})

      other ->
        Logger.warning("Decomposer: partition parse failed: #{inspect(other)}")
        %{state | error: "Failed to parse partition response"}
    end
  end

  def on_step_complete(_step, state), do: state

  # ---------------------------------------------------------------------------
  # Dynamic step generation - the core of the decomposer
  #
  # After estimation, decide whether to partition or go straight to a single
  # reviewer. After partitioning, fan out scoped reviewers (and optionally an
  # integration reviewer) followed by synthesis.
  # ---------------------------------------------------------------------------

  @impl AI.Agent.Composite
  def get_next_steps(%{name: :estimate}, state) do
    {:ok, estimate} = Composite.get_state(state, :estimate)

    case estimate.points do
      p when p < 3 ->
        # Small change - single reviewer with full scope, then synthesize.
        scope = build_small_scope(state.request, estimate)

        [
          Composite.delegate(:review_0, AI.Agent.Review.Reviewer, fn _s ->
            %{scope: scope}
          end),
          Composite.completion(:synthesize, @synthesis_prompt)
        ]

      _ ->
        # Partition first, then get_next_steps(:partition) handles fan-out.
        [
          Composite.completion(:partition, @partition_prompt,
            keep_prompt?: true,
            response_format: @partition_format
          )
        ]
    end
  end

  def get_next_steps(%{name: :partition}, state) do
    {:ok, estimate} = Composite.get_state(state, :estimate)
    {:ok, partition} = Composite.get_state(state, :partition)

    reviewers =
      partition.review_units
      |> Enum.with_index()
      |> Enum.map(fn {briefing, i} ->
        step_name = Enum.at(@reviewer_step_names, i, :"review_#{i}")

        Composite.delegate(step_name, AI.Agent.Review.Reviewer, fn _s ->
          %{scope: briefing}
        end)
      end)

    integration =
      case estimate.points do
        p when p >= 5 ->
          briefing = build_integration_briefing(state.request, estimate, partition)

          [
            Composite.delegate(:integration, AI.Agent.Review.Reviewer, fn _s ->
              %{scope: briefing}
            end)
          ]

        _ ->
          []
      end

    # Parallel group of all reviewers, then synthesize sequentially.
    [reviewers ++ integration, Composite.completion(:synthesize, @synthesis_prompt)]
  end

  def get_next_steps(_step, _state), do: []

  # Halt on any step failure. Parse failures from structured output indicate
  # API-level problems where retry won't help; reviewer delegation failures
  # mean the sub-agent's conversation is already in a bad state.
  @impl AI.Agent.Composite
  def on_error(_step, _error, state) do
    {:halt, state}
  end

  # ---------------------------------------------------------------------------
  # Scope builders
  # ---------------------------------------------------------------------------

  # For small changes (< 3 points), build a scope string that includes the git
  # range, diff stat, and exclude paths so the single Reviewer doesn't need to
  # re-fetch any of this.
  defp build_small_scope(original_scope, estimate) do
    exclude_note =
      case estimate.exclude_paths do
        [] ->
          ""

        paths ->
          "\n\nExclude these files from review (#{estimate.exclude_reasoning}):\n" <>
            Enum.map_join(paths, "\n", &"- #{&1}")
      end

    """
    #{original_scope}

    ## Git range

    Use `#{estimate.git_range}` for all git commands (diff, log, show, etc.).

    ## Diff stat

    ```
    #{estimate.diff_stat}
    ```
    #{exclude_note}\
    """
    |> String.trim()
  end

  # Build the integration reviewer's scope from the partition output. Lists each
  # review unit's summary so the integration reviewer knows what was covered
  # separately and can focus on the seams between them.
  defp build_integration_briefing(original_scope, estimate, partition) do
    units_summary =
      partition.review_units
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {briefing, i} ->
        # Take the first ~200 chars of each briefing as a summary
        summary = String.slice(briefing, 0, 200)
        trailing = if String.length(briefing) > 200, do: "...", else: ""
        "#{i}. #{summary}#{trailing}"
      end)

    exclude_paths =
      case estimate.exclude_paths do
        [] -> "(none)"
        paths -> Enum.join(paths, ", ")
      end

    @integration_briefing_template
    |> String.replace("GIT_RANGE", estimate.git_range)
    |> String.replace("REVIEW_UNITS_SUMMARY", units_summary)
    |> String.replace("EXCLUDE_PATHS", exclude_paths)
    |> String.replace("ORIGINAL_SCOPE", original_scope)
  end
end
