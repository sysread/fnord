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

  ## Range resolution - READ FIRST

  If the user message contains a `## Git context` section with a pre-resolved
  range (MERGE_BASE..HEAD with actual SHAs), USE IT AS-IS. It was computed
  deterministically by the host and is authoritative for "review this branch"
  style requests.

  Do NOT diff against the base branch directly (e.g. `main..HEAD` or
  `main...HEAD`) - the base may have advanced since this branch forked, which
  would pull unrelated commits into the review. Always use the resolved
  merge-base SHA from the supplied git context.

  Only override the supplied range when the user's scope explicitly specifies
  a different one (e.g. "the last 3 commits" -> `HEAD~3..HEAD`, "just commit
  abc123" -> `abc123^..abc123`). In that case, state why you overrode it.

  ## Process

  1. Use the supplied `git diff --stat` output if present in the git context.
     Otherwise run `git diff --stat <range>` against the resolved range.
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

  Produce a JSON object with your estimate. Include the exact git range you
  used (two-dot form with resolved SHAs, e.g. "a1b2c3d..HEAD" - NOT
  "main..HEAD" or "main...HEAD") and the full `git diff --stat` output so
  downstream reviewers don't have to re-fetch them.
  """

  @constraints_prompt """
  Extract the constraints and contract surface introduced or affected by this
  change.

  Read the PR description, commit messages, diff, tests, comments, and impacted
  code. Infer explicit and implicit invariants, and identify the contract surface
  that must remain true for callers up, callees down, and any disjoint code paths
  that depend on the impacted state.

  ## Output requirements

  Produce a JSON object that lists each constraint with:
  - an id
  - a type
  - a scope tag or tags
  - a confidence value
  - a statement of the constraint or invariant
  - citations with provenance from source kind plus file:line or commit hash and
    message line

  The output must cover the complete contract surface for this change.
  """

  @constraints_format %{
    type: "json_schema",
    json_schema: %{
      name: "review_constraints",
      schema: %{
        type: "object",
        required: ["constraints"],
        additionalProperties: false,
        properties: %{
          constraints: %{
            type: "array",
            minItems: 1,
            items: %{
              type: "object",
              required: ["id", "type", "scope", "confidence", "statement", "citations"],
              additionalProperties: false,
              properties: %{
                id: %{type: "string"},
                type: %{type: "string"},
                scope: %{type: "array", items: %{type: "string"}},
                confidence: %{type: "number", minimum: 0, maximum: 1},
                statement: %{type: "string"},
                citations: %{
                  type: "array",
                  minItems: 1,
                  items: %{
                    type: "object",
                    required: ["source_kind", "reference"],
                    additionalProperties: false,
                    properties: %{
                      source_kind: %{type: "string"},
                      reference: %{type: "string"}
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

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

  1. **Constraints-first grouping**: Re-list the applicable constraints at the top
     of the report, with citations. Group findings by the constraint they violate.
     This is the primary organization of the report.
  2. **Deduplicate**: The same issue may be flagged by multiple reviewers when
     it spans a component boundary. Merge these into a single finding.
  3. **Root-cause merge**: Multiple findings may stem from the same underlying
     issue (e.g., a contract mismatch causes errors in 3 call sites). Group
     these under the root cause.
  4. **Severity calibration**: Adjust severity based on the full picture. Severity
     remains important, but it is a sub-grouping or per-finding field after
     grouping by constraint.
  5. **Coverage check**: Note any files or areas that were not covered by any
     reviewer.

  ## Report format

  ### Scope
  - Branch/range reviewed
  - Estimated complexity (scrum points) and decomposition rationale
  - Applicable constraints with citations

  ### Findings

  Group findings by violated constraint first, then by severity (BLOCKING > HIGH >
  MEDIUM > LOW). For each:
  1. **Constraint id(s)** and **severity**
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

  ## Constraints

  CONSTRAINTS_SECTION

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
              "The resolved git range, two-dot form with resolved SHAs (e.g. 'a1b2c3d..HEAD' or 'HEAD~3..HEAD'). Do NOT use symbolic base-branch names like 'main..HEAD' or three-dot 'main...HEAD' - the base may have advanced since fork."
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

    # Resolve the review range deterministically from git state before the LLM
    # gets a chance to guess. Without this, a vague scope like "review this
    # branch" lets the LLM pick the wrong branch or diff against a symbolic
    # base (main..HEAD), which pulls in unrelated commits whenever main has
    # advanced since the branch forked. A nil result means we're not in a git
    # repo or the preflight failed; the LLM falls back to its own exploration.
    git_context_msg =
      case resolve_git_context() do
        {:ok, ctx} -> [AI.Util.user_msg(format_git_context(ctx))]
        _ -> []
      end

    state = %Composite{
      agent: agent,
      model: @model,
      toolbox: tools,
      request: scope,
      response: nil,
      error: nil,
      messages:
        [
          AI.Util.system_msg(AI.Util.project_context()),
          AI.Util.system_msg(@system_prompt)
        ] ++ git_context_msg ++ [AI.Util.user_msg(scope)],
      internal: %{},
      steps: [
        Composite.completion(:estimate, @estimate_prompt,
          keep_prompt?: true,
          response_format: @estimate_format
        ),
        Composite.completion(:constraints, @constraints_prompt,
          keep_prompt?: true,
          response_format: @constraints_format
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
        :constraints -> "Extracting constraints and contract surface"
        :partition -> "Decomposing into review units"
        :synthesize -> "Synthesizing review findings"
        :integration -> "Dispatching integration reviewer"
        name -> "Dispatching scoped reviewer #{name}"
      end

    UI.report_from(state.agent.name, label)

    # Test visibility: also emit a lightweight message for ExUnit assertions.
    # We avoid creating new atoms; try to convert to an existing atom if present.
    agent_name = state.agent.name
    send(self(), {:ui_report, agent_name, label})

    if is_binary(agent_name) do
      try do
        send(self(), {:ui_report, String.to_existing_atom(agent_name), label})
      rescue
        _ -> :ok
      end
    end

    state
  end

  # The structured completion steps use json_schema response_format, so parse
  # failures indicate API-level problems, not schema drift. Halting is
  # intentional: get_next_steps pattern-matches on :estimate/:constraints/:partition
  # state, so continuing without valid parsed data would crash downstream.
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

  def on_step_complete(%{name: :constraints}, state) do
    case SafeJson.decode_lenient(state.response, keys: :atoms!) do
      {:ok, %{constraints: constraints}} when is_list(constraints) and constraints != [] ->
        Composite.put_state(state, :constraints, %{constraints: constraints})

      other ->
        Logger.warning("Decomposer: constraints parse failed: #{inspect(other)}")
        %{state | error: "Failed to parse constraints response"}
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
  def get_next_steps(%{name: :constraints}, state) do
    {:ok, estimate} = Composite.get_state(state, :estimate)
    {:ok, constraints} = Composite.get_state(state, :constraints)

    case estimate.points do
      p when p < 3 ->
        scope = build_small_scope(state.request, estimate, constraints)

        [
          Composite.delegate(:review_0, AI.Agent.Review.Reviewer, fn _s ->
            %{scope: scope}
          end),
          Composite.completion(:synthesize, @synthesis_prompt)
        ]

      _ ->
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
          %{scope: prepend_constraints_section(briefing, state)}
        end)
      end)

    integration =
      case estimate.points do
        p when p >= 5 ->
          briefing = build_integration_briefing(state.request, estimate, partition, state)

          [
            Composite.delegate(:integration, AI.Agent.Review.Reviewer, fn _s ->
              %{scope: append_constraints_section(briefing, state)}
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
  defp build_small_scope(original_scope, estimate, constraints) do
    exclude_note =
      case estimate.exclude_paths do
        [] ->
          ""

        paths ->
          "\n\nExclude these files from review (#{estimate.exclude_reasoning}):\n" <>
            Enum.map_join(paths, "\n", &"- #{&1}")
      end

    constraints_section = render_constraints_section(constraints)

    """
    #{original_scope}

    #{constraints_section}

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

  @doc """
  Build the small-reviewer scope using only the original scope and estimate.

  Legacy/test helper: extracts `:constraints` from the estimate if present
  (tests may inject them), otherwise defaults to an empty list. Production
  flow uses build_small_scope/3 with constraints from composite state.
  """
  @spec build_small_scope(binary, map) :: binary
  def build_small_scope(original_scope, estimate) do
    constraints = Map.get(estimate, :constraints, [])
    build_small_scope(original_scope, estimate, constraints)
  end

  # Build the integration reviewer's scope from the partition output. Lists each
  # review unit's summary so the integration reviewer knows what was covered
  # separately and can focus on the seams between them.
  defp build_integration_briefing(original_scope, estimate, partition, state) do
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

    constraints_section =
      case Composite.get_state(state, :constraints) do
        {:ok, %{constraints: constraints}} -> render_constraints_section(constraints)
        _ -> "(none)"
      end

    @integration_briefing_template
    |> String.replace("GIT_RANGE", estimate.git_range)
    |> String.replace("REVIEW_UNITS_SUMMARY", units_summary)
    |> String.replace("EXCLUDE_PATHS", exclude_paths)
    |> String.replace("ORIGINAL_SCOPE", original_scope)
    |> String.replace("CONSTRAINTS_SECTION", constraints_section)
  end

  defp render_constraints_section(constraints) do
    constraints
    |> Enum.map_join("\n", fn constraint ->
      citations =
        constraint.citations
        |> Enum.map_join(", ", fn citation ->
          "#{citation.source_kind}: #{citation.reference}"
        end)

      "- #{constraint.id} | type=#{constraint.type} | scope=#{Enum.join(List.wrap(constraint.scope), ", ")} | confidence=#{constraint.confidence} | #{constraint.statement} | citations=#{citations}"
    end)
    |> case do
      "" -> "## Constraints\n\n(none)"
      lines -> "## Constraints\n\n" <> lines
    end
  end

  defp prepend_constraints_section(scope, state) do
    case Composite.get_state(state, :constraints) do
      {:ok, %{constraints: constraints}} ->
        render_constraints_section(constraints) <> "\n\n" <> scope

      _ ->
        scope
    end
  end

  defp append_constraints_section(scope, state) do
    case Composite.get_state(state, :constraints) do
      {:ok, %{constraints: constraints}} ->
        scope <> "\n\n" <> render_constraints_section(constraints)

      _ ->
        scope
    end
  end

  # ---------------------------------------------------------------------------
  # Git context preflight
  #
  # The LLM would otherwise guess the review range from the caller's scope
  # string ("review this branch"). Guessing produces two failure modes:
  #   1. Wrong branch: the LLM picks whatever branch name it finds in history.
  #   2. Drifting base: `main..HEAD` includes commits merged to main after the
  #      branch forked, so the review covers unrelated code.
  # We resolve current branch, base branch, and merge-base up front. The
  # two-dot range MERGE_BASE..HEAD is stable against base-branch advancement.
  # ---------------------------------------------------------------------------

  defp resolve_git_context do
    with {:ok, root} <- GitCli.Worktree.project_root(),
         branch when is_binary(branch) <- GitCli.Worktree.current_branch(root),
         {:ok, base} <- pick_base_branch(root, branch),
         {:ok, merge_base} <- git(root, ["merge-base", "HEAD", base]),
         range = "#{merge_base}..HEAD",
         {:ok, diff_stat} <- git(root, ["diff", "--stat", range]),
         {:ok, log} <- git(root, ["log", "--oneline", range]) do
      {:ok,
       %{
         branch: branch,
         base: base,
         merge_base: merge_base,
         range: range,
         diff_stat: String.trim(diff_stat),
         log: String.trim(log)
       }}
    else
      _ -> :error
    end
  end

  # Pick main or master as the base. If the current branch IS the base, skip
  # the preflight - "review this branch" against itself is meaningless and the
  # LLM will need to ask the user for a real range.
  defp pick_base_branch(root, branch) do
    cond do
      branch in ["main", "master"] ->
        :error

      match?({:ok, _}, git(root, ["show-ref", "--verify", "--quiet", "refs/heads/main"])) ->
        {:ok, "main"}

      match?({:ok, _}, git(root, ["show-ref", "--verify", "--quiet", "refs/heads/master"])) ->
        {:ok, "master"}

      true ->
        :error
    end
  end

  defp git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  defp format_git_context(ctx) do
    """
    ## Git context (authoritative - use this range)

    - Current branch: `#{ctx.branch}`
    - Base branch: `#{ctx.base}`
    - Merge-base: `#{ctx.merge_base}`
    - Review range: `#{ctx.range}`

    This range is the two-dot form with a resolved SHA for the merge-base, so
    it is stable even if `#{ctx.base}` advances during or after the review.
    Use this range for all git commands unless the user's scope explicitly
    specifies a different one.

    Do NOT diff against `#{ctx.base}` directly (`#{ctx.base}..HEAD` or
    `#{ctx.base}...HEAD`) - that would include commits merged to `#{ctx.base}`
    after this branch forked.

    ### git diff --stat #{ctx.range}

    ```
    #{ctx.diff_stat}
    ```

    ### git log --oneline #{ctx.range}

    ```
    #{ctx.log}
    ```
    """
  end
end
