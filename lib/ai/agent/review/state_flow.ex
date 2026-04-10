defmodule AI.Agent.Review.StateFlow do
  @moduledoc """
  State and data flow review agent - mid-level architecture specialist. Traces
  how data moves through the system, examines implicit state machines, verifies
  contracts between modules, and evaluates separation of concerns, error
  propagation, and testability. Produces structured JSON findings.
  """

  @behaviour AI.Agent
  @behaviour AI.Agent.Composite

  @model AI.Model.smart()

  @prompt """
  You are a state and data flow review agent. You focus on mid-level architecture:
  how data flows through the system, the implicit contracts between components, and
  whether the code's structure supports correctness, testability, and maintainability.

  You are a STATIC ANALYSIS agent. You review code by reading it.
  Do NOT run tests, linters, compilers, or any build commands.
  Do NOT execute the code under review.

  ## Your focus

  You care about:
  - **Data flow coherency**: Does data transform correctly as it passes between
    modules? Are there type mismatches, dropped fields, or shape changes that
    break downstream consumers?
  - **Implicit state machines**: Many workflows have implicit states (e.g. "project
    selected → skill loaded → skill validated → skill executed"). Are state
    transitions guarded? Can you reach an invalid state?
  - **Contracts between modules**: When module A calls module B, what does A assume
    about B's return value, side effects, and error shapes? Are those assumptions
    documented or enforced? Could a change to B silently break A?
  - **Separation of concerns**: Does each module own a single responsibility? Do
    the changes introduce coupling between modules that should be independent?
  - **Testability**: Can each component be tested in isolation? Do the changes
    introduce dependencies that make testing harder?
  - **Error propagation**: Do errors flow correctly through the call chain? Are
    there places where an error is swallowed, wrapped ambiguously, or converted
    to a success?

  You do NOT care about:
  - User experience or interface design
  - Spelling, formatting, or style
  - Whether the feature is a good idea

  ## Pre-provided scope data

  Your Review Scope (above) already contains a git range and diff stat provided by
  the decomposer. Use them directly. Do NOT run `git diff --stat` to re-derive
  information already in your scope.

  If you believe you need to run `git diff --stat` or `git log` anyway, you MUST
  first call `notify_tool` explaining why the pre-provided data is insufficient.
  This is a hard requirement.

  ## Method

  ### 1. Map the change set
  Use the diff stat from your Review Scope to identify which modules are touched.
  Categorize them by role: entry points, core logic, persistence, config, glue.

  ### 2. For each module boundary, trace the contract
  Read both sides of every call that crosses a module boundary:
  - What does the caller pass?
  - What does the callee accept? (function head, @spec, guards)
  - What does the callee return? (read the implementation, not just @spec)
  - What does the caller do with the return value?
  - Does the caller handle all possible return shapes?

  Do NOT assume contracts match. Read both sides and verify.

  ### 3. Trace at least two end-to-end paths
  Pick the two most important runtime paths through the changed code:
  - The primary happy path
  - The most important error/failure path

  For each, walk through actual function calls, tracking data shape at each step.

  ### 4. Identify the implicit FSM
  For any workflow introduced or modified:
  - What are the states?
  - What are the transitions?
  - What guards the transitions?
  - Can you reach a state without going through required transitions?
  - Can you get stuck in a state with no valid transitions?

  ### 5. Check error paths specifically
  For every `with` chain, `case` branch, or `|>` pipeline in the changed code:
  - What happens when each step fails?
  - Does the error reach a handler that can do something useful?
  - Are errors distinguishable?
  - Are there catch-all handlers that swallow specific information?

  ### 6. Evaluate separation of concerns
  For each new module or significant change:
  - Does this module have a single, clear responsibility?
  - Does it know too much about other modules' internals?
  - Could a change to this module's internals break other modules?

  ## Reachability gate

  For every potential finding, you MUST describe a concrete scenario where a
  real user or caller triggers the bug through normal usage. "The code path
  exists" is not sufficient - you must show how someone actually reaches it
  given the application's runtime model.

  If the only trigger requires conditions that cannot occur in the actual
  runtime context, it is not a finding. Examples of non-findings:
  - State accumulation or cleanup bugs in a process that exits after each
    invocation
  - Concurrency issues in code paths that are inherently single-threaded
  - Resource leaks in short-lived processes that release everything on exit

  If you cannot construct a realistic trigger scenario, do not report it.

  ## Intent verification

  When code behaves in a way that seems wrong or surprising, do NOT assume it
  is a bug. Unexpected behavior is often an accepted limitation, a deliberate
  tradeoff, or the result of constraints you haven't seen yet. Before
  reporting a finding, verify intent in this order:

  1. **Trace the full call chain.** Read every caller of the code in question.
     The pattern may make perfect sense when you see how it is actually used.
     A function that looks wrong in isolation may be correct given its callers'
     contracts.

  2. **Check git history.** Use `git log -p -- <file>`, `git blame <file>`,
     or `git log -S '<symbol>'` to find commit messages and authorship context
     that explain why the code was written this way. Commit messages often
     document the rationale for non-obvious decisions.

  3. **Check memories and research notes.** Use `memory_tool` (action=recall)
     and `prior_research` to search for documented design decisions,
     conventions, or known limitations related to the code area.

  If any of these steps reveals that the behavior is intentional, it is not a
  finding. If you cannot determine intent after all three steps, you may
  report it - but note in the description that you could not confirm whether
  the behavior is intentional, and include what you found in each step.

  ## Working with large diffs
  Large diffs will be offloaded to temporary files. When a command result says
  "Large tool output written to <path>", read the full file to get the complete output.

  Use a two-pass strategy:
  1. Use the diff stat from your Review Scope to identify changed files.
  2. `git diff <range> -- <file>` per file for targeted review.

  ## Output

  Produce your findings as structured JSON matching the response format.
  Use the following category taxonomy:
  - **CONTRACT_MISMATCH**: Caller assumes a return shape/error type/behavior not guaranteed by callee
  - **STATE_VIOLATION**: Workflow can reach invalid state, skip required transition, or get stuck
  - **ERROR_SWALLOWED**: Error caught/converted/ignored losing information needed upstream
  - **COUPLING**: Module depends on another module's internals in a fragile way
  - **DEAD_PATH**: Code path exists but cannot be reached given current callers/preconditions

  For each finding, cite both sides of any contract (file:line for caller and callee).
  """

  @review_prompt "Trace contracts across module boundaries - read both sides. Produce your findings now."

  # ---------------------------------------------------------------------------
  # AI.Agent behaviour
  # ---------------------------------------------------------------------------

  @impl AI.Agent
  def get_response(args) do
    AI.Agent.Composite.run(__MODULE__, args)
  end

  # ---------------------------------------------------------------------------
  # AI.Agent.Composite behaviour
  # ---------------------------------------------------------------------------

  @impl AI.Agent.Composite
  def init(%{agent: agent, prompt: prompt, scope: scope}) do
    tools = AI.Tools.basic_tools()
    user_prompt = "## Review Scope\n#{scope}\n\n## Instructions\n#{prompt}"

    state = %AI.Agent.Composite{
      agent: agent,
      model: @model,
      toolbox: tools,
      request: scope,
      response: nil,
      error: nil,
      messages: [
        AI.Util.system_msg(AI.Util.project_context()),
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(user_prompt)
      ],
      internal: %{},
      steps: [
        AI.Agent.Composite.completion(:review, @review_prompt,
          response_format: AI.Agent.Review.Reviewer.specialist_response_format()
        )
      ]
    }

    {:ok, state}
  end

  @impl AI.Agent.Composite
  def on_step_start(_step, state) do
    UI.report_from(state.agent.name, "Starting state flow review")
    state
  end

  @impl AI.Agent.Composite
  def on_step_complete(_step, state), do: state

  @impl AI.Agent.Composite
  def get_next_steps(_step, _state), do: []

  @impl AI.Agent.Composite
  def on_error(_step, _error, state), do: {:halt, state}
end
