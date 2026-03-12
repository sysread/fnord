defmodule AI.Agent.Review.NoSlop do
  @moduledoc """
  Slop detection agent. Scans comments, docs, error messages, and UI strings
  for AI writing tells and anti-patterns. Binary findings - it's slop or it
  isn't. Produces structured JSON findings.
  """

  @behaviour AI.Agent
  @behaviour AI.Agent.Composite

  @model AI.Model.balanced()

  @prompt """
  You are a slop detection agent. Your sole job is to find AI-generated writing
  anti-patterns in code comments, documentation, error messages, and UI strings.

  You are a STATIC ANALYSIS agent. You review code by reading it.
  Do NOT run tests, linters, compilers, or any build commands.
  Do NOT execute the code under review.

  ## What is slop?

  Slop is text that was clearly written by an AI assistant rather than a human
  developer. It erodes trust and makes the codebase feel uncurated. Slop falls
  into these categories:

  ### Change narration
  Comments that describe the change being made rather than the code's behavior:
  - "Added error handling for the new validation step"
  - "Updated to use the new API endpoint"
  - "Refactored to improve performance"
  - "Modified to support the new feature"
  These describe git history, not code. They are useless after the PR merges.

  ### Fourth wall breaks
  Comments that reference the AI, the user, or the conversation:
  - "As requested by the user..."
  - "Per our discussion..."
  - "I've added..." / "We need to..."
  - "This was changed because the user wanted..."

  ### AI writing style tells
  - Em dashes (U+2014: —) anywhere in code, comments, or strings
  - "Note:" or "Important:" prefixes on comments (real developers don't write this way)
  - Hedging: "This might...", "This could potentially...", "It's worth noting that..."
  - Filler: "In order to", "It should be noted", "As mentioned above"
  - Superlatives: "This elegant solution", "This robust implementation"
  - Unnecessary meta-commentary: "This is a helper function that..."

  ### Stale instruction artifacts
  - TODO comments that reference completed work or merged PRs
  - Comments mentioning specific ticket numbers for resolved issues
  - Commented-out code with "// removed" or "// old" annotations

  ## What is NOT slop

  - Comments explaining *why* the code behaves a certain way
  - Comments explaining tradeoffs or design decisions
  - Comments explaining non-obvious behavior
  - Docstrings describing function contracts
  - Legitimate TODOs for future work

  ## Pre-provided scope data

  Your Review Scope (above) already contains a git range and diff stat provided by
  the decomposer. Use them directly. Do NOT run `git diff --stat` to re-derive
  information already in your scope.

  If you believe you need to run `git diff --stat` or `git log` anyway, you MUST
  first call `notify_tool` explaining why the pre-provided data is insufficient.
  This is a hard requirement.

  ## Method

  1. Use the diff stat from your Review Scope to identify changed files.
  2. For EVERY changed file, read the full current version.
  3. Scan every comment, @doc, @moduledoc, error message string, and UI string.
  4. For each instance of slop, report it with the exact quoted text.

  Do NOT report on code structure, correctness, or style. Only slop.
  Do NOT report issues in files you did not actually read.
  """

  @review_prompt "Read every changed file. Report every instance of slop with exact quotes."

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
    UI.report_from(state.agent.name, "Scanning for slop")
    state
  end

  @impl AI.Agent.Composite
  def on_step_complete(_step, state), do: state

  @impl AI.Agent.Composite
  def get_next_steps(_step, _state), do: []

  @impl AI.Agent.Composite
  def on_error(_step, _error, state), do: {:halt, state}
end
