defmodule AI.Agent.Review.Reviewer do
  @moduledoc """
  Master review agent. Coordinates a comprehensive post-implementation review
  by researching the change, dispatching five specialist reviewers in parallel,
  confirming their findings against the actual code, and producing a unified
  severity-grouped report.

  ## Pipeline

  1. **Formulate** - research the change and produce tailored prompts for each
     specialist reviewer.
  2. **Specialists** - five specialists (pedantic, acceptance, state flow,
     no-slop, breadcrumbs) run in parallel, each producing structured findings
     in their domain.
  3. **Incorporate** - confirm each finding by reading the cited code, classify
     as CONFIRMED/REJECTED/UNVERIFIABLE, and produce the final report.
  """

  @behaviour AI.Agent
  @behaviour AI.Agent.Composite

  require Logger

  @model AI.Model.smart()

  # ---------------------------------------------------------------------------
  # Prompts
  # ---------------------------------------------------------------------------

  @system_prompt """
  You are the lead reviewer coordinating a comprehensive code review.

  You are a STATIC ANALYSIS agent. You review code by reading it.
  Do NOT run tests, linters, compilers, or any build commands.
  Do NOT execute the code under review.
  """

  @formulation_prompt """
  Your first job is to understand the change and formulate targeted review prompts
  for five specialist agents.

  ## Step 1: Understand the change

  Your scope description may already include a git range and diff stat. If so,
  use them directly - do NOT re-run `git diff --stat` or `git log`. Only run
  git commands for data not already provided in your scope.

  If the scope does NOT include a diff stat:
  1. Run `git diff --stat` on the specified range to identify changed files.
  2. Read the diffs for each changed file to understand what was modified.

  In either case:
  3. If design context was provided, use it. Otherwise, infer the design intent
     from commit messages (`git log --oneline <range>`) and the code itself.
  4. Note any aspects of the change that seem unusual, unrelated to the stated
     purpose, or potentially risky.

  ## Step 2: Formulate specialist prompts

  You have five specialists, each with a different focus:

  1. **Pedantic** - mechanical correctness: spelling, naming, doc accuracy, specs,
     guidelines, stale artifacts. Needs to know which files to read and what
     conventions to check against.

  2. **Acceptance** - behavioral/product review: UX coherency, behavioral delta,
     integration effects, user assumptions. Needs to know the before-state and
     the intended behavior so it can evaluate whether the change delivers.

  3. **State Flow** - data flow and contracts: module boundaries, implicit FSMs,
     error propagation, separation of concerns. Needs to know which module
     boundaries to trace and what the expected data shapes are.

  4. **NoSlop** - AI writing anti-pattern detection: change narration comments,
     fourth wall breaks, em dashes, hedging language, filler phrases, stale
     instruction artifacts. Needs to know which files to scan.

  5. **BreadCrumbs** - comment narrative evaluation: do comments form a coherent
     outline of the code's behavior? Do new modules/functions explain how they
     fit into the larger system? Could a developer reconstruct the purpose from
     comments alone? Needs the full file context, not just diffs.

  For each specialist, write a prompt that:
  - States the review scope (branch range, changed files)
  - Provides relevant design context
  - Highlights specific areas of concern you identified in Step 1
  - Gives the specialist enough context to do focused, high-quality work
  - Calls out anything unusual (e.g., "3 of these changes appear to be bugfixes
    not mentioned in the design - review these separately")

  Produce a JSON object with the specialist prompts and your scope summary.
  """

  @aggregation_prompt """
  You have received reports from five specialist reviewers. Your job now is to
  verify their citations and produce a single, coherent report.

  ## Verification process

  Each specialist finding includes a `location` (file:line) and `evidence`
  (quoted code). For each finding:

  1. Read the cited file at the cited line to verify the evidence matches.
     Only read the specific location - do NOT re-run `git diff --stat`,
     `git log`, or other broad research commands. That work is already done.
  2. Check whether the quoted code actually exists at that location and
     whether the specialist's claim about its behavior is accurate.
  3. Determine whether the finding is a new issue introduced by this change or a
     pre-existing problem. Note pre-existing bugs identified separately.
  4. Determine whether the finding can be realistically reproduced in normal
     usage, if it requires unusual conditions, or if it's a technical or
     theoretical flaw that is unlikely to manifest in practice.
  5. Classify:
     - **CONFIRMED**: The cited code matches and the claim is accurate.
     - **REJECTED**: The citation is wrong or the claim is inaccurate (explain
       why briefly).
     - **UNVERIFIABLE**: The citation is correct but you cannot confirm the
       behavioral claim without deeper tracing (state what's missing).

  If a citation clearly does not match the file contents (e.g., wrong line
  numbers, code that doesn't exist, or content from a different branch), you
  may do targeted investigation to determine what actually happened. This is
  the ONLY situation where broader git commands are justified during
  verification.

  ## Severity calibration

  Assign final severity based on YOUR verification:
  - **BLOCKING**: Incorrect behavior that will manifest in normal usage. You
    confirmed the cited code behaves as the specialist described.
  - **HIGH**: A real bug that requires specific but realistic conditions. You
    verified the conditions are reachable from the cited location.
  - **MEDIUM**: Edge cases, UX friction, or issues where the citation is correct
    but the impact is limited or requires unusual conditions.
  - **LOW**: Mechanical issues (stale docs, guideline violations, naming) that
    don't affect correctness.

  ## Report format

  ### Scope
  - Branch/range reviewed
  - Design context (if provided)

  ### Confirmed findings
  For each finding, grouped by severity (BLOCKING > HIGH > MEDIUM > LOW):
  1. **Severity** and **category** (from the specialist's taxonomy)
  2. **Source**: which specialist found it
  3. **Location**: file:line
  4. **Finding**: what the problem is
  5. **Evidence**: the code you read to confirm it
  6. **Provenance**: branch-introduced or pre-existing

  ### Rejected findings (appendix, brief)
  Findings you rejected and a one-line reason why.

  ### Pre-existing bugs (appendix, brief)
  Findings you verified as real but pre-existing, with a one-line note on the
  issue and its potential impact.

  ### Coverage gaps
  Note which files or areas were NOT covered by any specialist.
  """

  # ---------------------------------------------------------------------------
  # Response formats
  # ---------------------------------------------------------------------------

  @formulation_response_format %{
    type: "json_schema",
    json_schema: %{
      name: "review_formulation",
      schema: %{
        type: "object",
        required: [
          "scope_summary",
          "pedantic_prompt",
          "acceptance_prompt",
          "state_flow_prompt",
          "no_slop_prompt",
          "breadcrumbs_prompt"
        ],
        additionalProperties: false,
        properties: %{
          scope_summary: %{
            type: "string",
            description:
              "Brief summary of what the change does, which files are affected, and any design context."
          },
          design_context: %{
            type: "string",
            description:
              "Design intent inferred from commits, docs, or caller-provided context. Empty string if none."
          },
          pedantic_prompt: %{
            type: "string",
            description: "Tailored review prompt for the pedantic specialist."
          },
          acceptance_prompt: %{
            type: "string",
            description: "Tailored review prompt for the acceptance specialist."
          },
          state_flow_prompt: %{
            type: "string",
            description: "Tailored review prompt for the state flow specialist."
          },
          no_slop_prompt: %{
            type: "string",
            description: "Tailored review prompt for the slop detection specialist."
          },
          breadcrumbs_prompt: %{
            type: "string",
            description: "Tailored review prompt for the comment narrative specialist."
          }
        }
      }
    }
  }

  @specialist_response_format %{
    type: "json_schema",
    json_schema: %{
      name: "review_findings",
      schema: %{
        type: "object",
        required: ["findings", "files_reviewed"],
        additionalProperties: false,
        properties: %{
          findings: %{
            type: "array",
            items: %{
              type: "object",
              required: [
                "category",
                "severity",
                "location",
                "description",
                "evidence",
                "provenance"
              ],
              additionalProperties: false,
              properties: %{
                category: %{
                  type: "string",
                  description:
                    "Finding category from the specialist's taxonomy (e.g. STALE, FRICTION, CONTRACT_MISMATCH)"
                },
                severity: %{
                  type: "string",
                  enum: ["BLOCKING", "HIGH", "MEDIUM", "LOW"]
                },
                location: %{
                  type: "string",
                  description:
                    "Exact file:line reference (e.g., 'lib/foo.ex:42'). Must match where you read the code."
                },
                description: %{type: "string", description: "What the problem is"},
                evidence: %{
                  type: "string",
                  description:
                    "Exact code quoted from the cited location. Copy-paste from what you read - do not paraphrase."
                },
                provenance: %{
                  type: "string",
                  enum: ["branch-introduced", "pre-existing"]
                }
              }
            }
          },
          files_reviewed: %{
            type: "array",
            items: %{type: "string"},
            description: "List of files this specialist actually read"
          },
          coverage_gaps: %{
            type: "array",
            items: %{type: "string"},
            description: "Files or areas in scope that were not reviewed"
          }
        }
      }
    }
  }

  @doc "The JSON schema response format used by specialist agents."
  @spec specialist_response_format() :: map
  def specialist_response_format, do: @specialist_response_format

  # ---------------------------------------------------------------------------
  # AI.Agent behaviour - entry point from the tool
  # ---------------------------------------------------------------------------

  @impl AI.Agent
  def get_response(args) do
    AI.Agent.Composite.run(__MODULE__, args)
  end

  # ---------------------------------------------------------------------------
  # AI.Agent.Composite behaviour - step-based execution
  # ---------------------------------------------------------------------------

  @impl AI.Agent.Composite
  def init(%{agent: agent, scope: scope}) do
    tools = AI.Tools.basic_tools()

    state = %AI.Agent.Composite{
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
        AI.Agent.Composite.completion(:formulate, @formulation_prompt,
          response_format: @formulation_response_format
        ),
        [
          AI.Agent.Composite.delegate(:pedantic, AI.Agent.Review.Pedantic, fn state ->
            {:ok, prompts} = AI.Agent.Composite.get_state(state, :specialist_prompts)
            %{prompt: prompts.pedantic_prompt, scope: state.request}
          end),
          AI.Agent.Composite.delegate(:acceptance, AI.Agent.Review.Acceptance, fn state ->
            {:ok, prompts} = AI.Agent.Composite.get_state(state, :specialist_prompts)
            %{prompt: prompts.acceptance_prompt, scope: state.request}
          end),
          AI.Agent.Composite.delegate(:state_flow, AI.Agent.Review.StateFlow, fn state ->
            {:ok, prompts} = AI.Agent.Composite.get_state(state, :specialist_prompts)
            %{prompt: prompts.state_flow_prompt, scope: state.request}
          end),
          AI.Agent.Composite.delegate(:no_slop, AI.Agent.Review.NoSlop, fn state ->
            {:ok, prompts} = AI.Agent.Composite.get_state(state, :specialist_prompts)
            %{prompt: prompts.no_slop_prompt, scope: state.request}
          end),
          AI.Agent.Composite.delegate(:breadcrumbs, AI.Agent.Review.BreadCrumbs, fn state ->
            {:ok, prompts} = AI.Agent.Composite.get_state(state, :specialist_prompts)
            %{prompt: prompts.breadcrumbs_prompt, scope: state.request}
          end)
        ],
        AI.Agent.Composite.completion(:incorporate, @aggregation_prompt)
      ]
    }

    {:ok, state}
  end

  @impl AI.Agent.Composite
  def on_step_start(step, state) do
    label =
      case step.name do
        :formulate -> "Researching change and formulating review prompts"
        :pedantic -> "Dispatching pedantic reviewer"
        :acceptance -> "Dispatching acceptance reviewer"
        :state_flow -> "Dispatching state flow reviewer"
        :no_slop -> "Dispatching slop detector"
        :breadcrumbs -> "Dispatching comment narrative reviewer"
        :incorporate -> "Confirming findings and producing final report"
      end

    UI.report_from(state.agent.name, label)
    state
  end

  @impl AI.Agent.Composite
  def on_step_complete(%{name: :formulate}, state) do
    case SafeJson.decode_lenient(state.response, keys: :atoms!) do
      {:ok,
       %{
         pedantic_prompt: _,
         acceptance_prompt: _,
         state_flow_prompt: _,
         no_slop_prompt: _,
         breadcrumbs_prompt: _
       } = prompts} ->
        AI.Agent.Composite.put_state(state, :specialist_prompts, prompts)

      other ->
        Logger.warning("Reviewer: formulation parse failed: #{inspect(other)}")
        %{state | error: "Failed to parse formulation response"}
    end
  end

  def on_step_complete(_step, state), do: state

  @impl AI.Agent.Composite
  def get_next_steps(_step, _state), do: []

  @impl AI.Agent.Composite
  def on_error(_step, _error, state) do
    {:halt, state}
  end
end
