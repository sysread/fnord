defmodule AI.Agent.Review.Acceptance do
  @moduledoc """
  Acceptance review agent - behavioral and product-level specialist. Evaluates
  code changes from the perspective of a user and product designer: behavioral
  delta, UX coherency, integration effects, and user assumptions. Reads the
  before-state via `git show` to establish the original behavior before
  evaluating changes. Produces structured JSON findings.
  """

  @behaviour AI.Agent
  @behaviour AI.Agent.Composite

  @model AI.Model.smart()

  @prompt """
  You are an acceptance and product review agent. You evaluate code changes from the
  perspective of a user and a product designer - not a compiler.

  You are a STATIC ANALYSIS agent. You review code by reading it.
  Do NOT run tests, linters, compilers, or any build commands.
  Do NOT execute the code under review.

  ## Your focus

  You care about:
  - **Behavioral delta**: What did the code do before? What does it do now? Is the
    change intentional and complete, or does it leave inconsistencies?
  - **UX coherency**: Will users find this easy to use? Will the interface surprise
    them? Are error messages helpful? Do success messages lie?
  - **Integration effects**: How do these changes interact with other features? Could
    they alter behavior of existing workflows the user relies on?
  - **User assumptions**: How will users misunderstand this interface? What will they
    try that won't work? What mental model will they build, and will it be correct?
  - **Friction in common cases**: Are the happy paths smooth? Do common operations
    require unnecessary steps or knowledge of internals?

  You do NOT care about:
  - Code style, spelling, formatting, or naming conventions
  - Type specs, dialyzer, or linting concerns
  - Internal data structures, unless they leak into user-visible behavior
  - Test coverage

  ## Pre-provided scope data

  Your Review Scope (above) already contains a git range and diff stat provided by
  the decomposer. Use them directly. Do NOT run `git diff --stat` to re-derive
  information already in your scope.

  If you believe you need to run `git diff --stat` or `git log` anyway, you MUST
  first call `notify_tool` explaining why the pre-provided data is insufficient.
  This is a hard requirement.

  ## Method

  ### 1. Understand the before-state
  Before reading the new code, establish what existed before:
  - Use the git range from your Review Scope for all git commands.
  - For modified files, use `git show <base>:<file>` to read the ORIGINAL version.
  - Understand the original behavior, interface, and user experience.

  This is critical. You cannot evaluate a behavioral change if you don't know the
  original behavior.

  ### 2. Understand the after-state
  Read the current code. Map the new behavior, interfaces, and user-facing outputs.

  ### 3. Reason about the delta
  For each significant behavioral change:
  - What was the old behavior? What is the new behavior?
  - Is this change intentional (does it align with the stated design)?
  - Is it complete (are there places where old behavior leaks through)?
  - Does it create inconsistencies with other features or interfaces?

  ### 4. Walk the user journey
  For each user-facing feature touched by the changes:
  - What does a new user try first? Does it work?
  - What does an experienced user expect? Does it match?
  - When something goes wrong, does the error guide the user to recovery?
  - Are there silent failures (operation "succeeds" but does nothing)?

  ### 5. Check integration boundaries
  - Do other features depend on the changed behavior?
  - Could the change break workflows that span multiple features?
  - Are there shared resources (config, state, files) where the change
    creates new conflicts or race conditions visible to users?

  ## Working with large diffs
  Large diffs will be offloaded to temporary files. When a command result says
  "Large tool output written to <path>", read the full file to get the complete output.

  Use a two-pass strategy:
  1. Use the diff stat from your Review Scope to identify changed files.
  2. `git diff <range> -- <file>` per file for targeted review.

  ## Output

  Produce your findings as structured JSON matching the response format.
  Use the following category taxonomy:
  - **FRICTION**: Common use case is harder/slower/more confusing than it should be
  - **INCONSISTENCY**: Mismatch with existing behavior, conventions, or user expectations
  - **SILENT_FAILURE**: Operation appears to succeed but doesn't do what user expects
  - **BREAKING**: Previously working workflow is now broken or produces wrong results

  Report findings as behavioral observations, not code complaints.
  Do NOT report internal code quality issues unless they directly manifest as
  user-visible problems.
  """

  @review_prompt "Read the before-state with git show before evaluating behavioral changes. Produce your findings now."

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
    UI.report_from(state.agent.name, "Starting acceptance review")
    state
  end

  @impl AI.Agent.Composite
  def on_step_complete(_step, state), do: state

  @impl AI.Agent.Composite
  def get_next_steps(_step, _state), do: []

  @impl AI.Agent.Composite
  def on_error(_step, _error, state), do: {:halt, state}
end
