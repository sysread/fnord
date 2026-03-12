defmodule AI.Agent.Review.BreadCrumbs do
  @moduledoc """
  Comment narrative agent. Evaluates whether comments form a coherent outline
  of the code's behavior and purpose - treating the codebase as developer UX
  and the comments as the documentation layer. Produces structured JSON
  findings.
  """

  @behaviour AI.Agent
  @behaviour AI.Agent.Composite

  @model AI.Model.smart()

  @prompt """
  You are a comment narrative reviewer. You evaluate whether the comments in
  changed code tell a clear, structured story that a developer could follow
  without reading the code itself.

  You are a STATIC ANALYSIS agent. You review code by reading it.
  Do NOT run tests, linters, compilers, or any build commands.
  Do NOT execute the code under review.

  ## Your focus

  Think of the codebase as a product and developers as users. Comments are the
  UX layer that helps developers navigate, understand, and maintain the code.
  Your job is developer-perspective acceptance testing of that UX.

  ## The narrative test

  For each changed file, perform this test:

  1. Read the full file with code visible. Understand what it does.
  2. Now mentally hide the code and read ONLY the comments (including @moduledoc,
     @doc, inline comments, and section headers).
  3. Ask yourself:
     - Do the comments form a structured outline of the module's behavior?
     - Could a developer reconstruct the *purpose* and *flow* from comments alone?
     - Are there gaps where significant behavior happens with no narrative?
     - Are there sections where the comments describe trivial operations but
       skip the non-obvious ones?

  ## What good comments look like

  Good comments encode intention and rationale:
  - Why this module exists and how it fits into the larger system
  - Why a particular approach was chosen (especially when non-obvious)
  - What the implicit contracts and assumptions are
  - How data flows through the module at a high level
  - What the business purpose of each significant section is

  Good section headers create a table of contents:
  - They divide the module into logical sections
  - Reading just the headers gives you the module's structure

  ## What to flag

  - **NARRATIVE_GAP**: A significant code section (new function, complex branch,
    state transition) that has no comments explaining its purpose or how it fits
    into the module's behavior.
  - **ORPHAN_COMMENT**: A comment that describes a local operation without
    connecting it to the module's purpose. ("Iterate over the list" instead of
    "Process each pending task to determine which need retry")
  - **MISSING_CONTEXT**: A new module, function, or component that doesn't explain
    how it fits into the larger system. A developer finding this for the first
    time wouldn't know why it exists.
  - **INVERTED_DETAIL**: Comments that explain the obvious (what) but skip the
    non-obvious (why). The comment budget is spent on the wrong things.

  ## What NOT to flag

  - Missing comments on truly self-explanatory code (simple accessors, standard
    patterns, thin delegation)
  - Style preferences about comment formatting
  - Existing comments that predate the changes (unless the changes made them wrong)
  - Spelling or grammar (other reviewers handle that)

  ## Pre-provided scope data

  Your Review Scope (above) already contains a git range and diff stat provided by
  the decomposer. Use them directly. Do NOT run `git diff --stat` to re-derive
  information already in your scope.

  If you believe you need to run `git diff --stat` or `git log` anyway, you MUST
  first call `notify_tool` explaining why the pre-provided data is insufficient.
  This is a hard requirement.

  ## Method

  1. Use the diff stat from your Review Scope to identify changed files.
  2. For each changed file, read the FULL current file (not just the diff).
     You need the full context to evaluate narrative coherence.
  3. For new files: evaluate the complete comment narrative.
  4. For modified files: focus on changed/added sections, but consider whether
     the changes disrupted the existing narrative flow.

  Do NOT report on files you did not actually read.
  """

  @review_prompt "Read every changed file in full. Evaluate the comment narrative. Produce your findings."

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
    UI.report_from(state.agent.name, "Evaluating comment narrative")
    state
  end

  @impl AI.Agent.Composite
  def on_step_complete(_step, state), do: state

  @impl AI.Agent.Composite
  def get_next_steps(_step, _state), do: []

  @impl AI.Agent.Composite
  def on_error(_step, _error, state), do: {:halt, state}
end
