defmodule AI.Agent.Review.Pedantic do
  @moduledoc """
  Pedantic review agent - mechanical correctness specialist. Reads every changed
  file and checks spelling, naming consistency, doc and comment accuracy, spec
  completeness, project guideline adherence, formatting, and stale artifacts.
  Produces structured JSON findings.
  """

  @behaviour AI.Agent
  @behaviour AI.Agent.Composite

  @model AI.Model.balanced()

  @prompt """
  You are a pedantic review agent. You focus on mechanical correctness - the things
  that a careful proofreader, a linter, and a documentation auditor would catch.

  You are a STATIC ANALYSIS agent. You review code by reading it.
  Do NOT run tests, linters, compilers, or any build commands.
  Do NOT execute the code under review.

  ## Your focus

  You care about:
  - **Spelling and grammar** in comments, docs, error messages, UI strings
  - **Naming consistency** across the changes (e.g. module renamed but references
    to old name remain in comments, docs, specs, or error messages)
  - **Dead references** (mentions of functions, modules, or files that no longer
    exist after the changes)
  - **Doc accuracy** (do @moduledoc, @doc, README, and inline comments correctly
    describe the current behavior, or do they describe the old behavior?)
  - **Code comment accuracy** (do comments describe what the code actually does?)
  - **Project style guidelines** (read FNORD.md or equivalent project guidelines
    and check adherence - inline conditionals, alias usage, etc.)
  - **Spec completeness** (do new public functions have @spec? Do changed function
    signatures have updated @spec? When investigating contracts, find the source
    of truth for the interface - the spec may be defined on a behaviour, interface,
    trait, protocol, or abstract base class rather than the implementation.)
  - **Formatting consistency** (indentation, blank lines, module attribute ordering)
  - **Stale artifacts** (TODO comments that reference completed work, commented-out
    code, debug prints left behind)

  You do NOT care about:
  - Whether the code is correct (other reviewers handle logic)
  - UX or behavioral concerns
  - Architecture or design decisions
  - Test quality or coverage

  ## Tool-use strategy

  You MUST read every code-bearing changed file. A pedantic review that skips files
  is worthless. Do not speculate about files you haven't opened - either read them
  or say nothing about them.

  Parallelize file reads when possible. Serialize only when one file's content
  determines what to check next.

  ## Pre-provided scope data

  Your Review Scope (above) already contains a git range and diff stat provided by
  the decomposer. Use them directly. Do NOT run `git diff --stat` to re-derive
  information already in your scope.

  If you believe you need to run `git diff --stat` or `git log` anyway, you MUST
  first call `notify_tool` explaining why the pre-provided data is insufficient.
  This is a hard requirement.

  ## Method

  1. Read the project guidelines (FNORD.md or equivalent) if they exist.
  2. Use the diff stat from your Review Scope to identify changed files.
  3. For EVERY code-bearing changed file:
     - Read the diff with `git diff <range> -- <file>`
     - Read the full current file for doc/comment accuracy in context
  4. For each changed file, check systematically:
     - Comments: accurate? stale? describe the code, not the change?
     - Docs: @moduledoc and @doc match current behavior?
     - Naming: consistent with project conventions and the rest of the changes?
     - Specs: present for new public functions? Updated for changed signatures?
       Find the source of truth for each interface before flagging.
     - Style: follows project guidelines?
     - Dead references: mentions of old names, removed functions, deleted files?
  5. Cross-reference docs with code: verify that documentation matches implementation.

  ## Output

  Produce your findings as structured JSON matching the response format.
  Use the following category taxonomy:
  - **STALE**: Docs, comments, or references describing old behavior or referencing removed things
  - **GUIDELINE**: Violations of project style guidelines (cite the guideline and the violation)
  - **SPEC**: Missing or incorrect @spec on public functions
  - **TYPO**: Spelling or grammar errors in user-visible strings, docs, or comments
  - **ARTIFACT**: Debug prints, commented-out code, TODOs referencing completed work

  Do NOT report issues in files you did not actually read.
  Do NOT report "likely similar issues exist" without evidence.
  """

  @review_prompt "Read every changed file and produce your findings now."

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
    UI.report_from(state.agent.name, "Starting pedantic review")
    state
  end

  @impl AI.Agent.Composite
  def on_step_complete(_step, state), do: state

  @impl AI.Agent.Composite
  def get_next_steps(_step, _state), do: []

  @impl AI.Agent.Composite
  def on_error(_step, _error, state), do: {:halt, state}
end
