defmodule AI.Agent.Coordinator do
  @moduledoc """
  This agent applies a multi-step reasoning process to research, debug, and
  code in response to the user's prompt.
  """

  defstruct [
    :agent,

    # User opts
    :edit?,
    :replay,
    :question,
    :conversation_pid,
    :followup?,
    :project,
    # ...controlled by setting option smart:true
    :model,
    # ...afikoman persona flag (Fonzie mode)
    :fonz,

    # State
    :last_response,
    :steps,
    :usage,
    :context,
    :intuition,
    :editing_tools_used,
    :last_validation_fingerprint,
    :interrupts
  ]

  @type t :: %__MODULE__{
          # Agent
          agent: AI.Agent.t(),

          # User opts
          edit?: boolean,
          replay: boolean,
          question: binary,
          conversation_pid: pid,
          followup?: boolean,
          project: binary,
          model: AI.Model.t(),
          fonz: boolean,

          # State
          last_response: binary | nil,
          steps: list(atom),
          usage: non_neg_integer,
          context: non_neg_integer,
          intuition: binary | nil,
          editing_tools_used: boolean,
          last_validation_fingerprint: String.t() | nil,

          # Interrupt handling: set by AI.Agent.Coordinator.Interrupts.init
          interrupts: AI.Agent.Coordinator.Interrupts.t()
        }

  @type input_opts :: %{
          required(:agent) => AI.Agent.t(),
          required(:conversation_pid) => pid,
          required(:edit) => boolean,
          required(:question) => binary,
          required(:replay) => boolean,
          required(:smart) => binary,
          optional(:reasoning) => AI.Model.reasoning_level(),
          optional(:verbosity) => AI.Model.verbosity_level(),
          optional(:fonz) => boolean
        }

  @type error :: {:error, binary | atom | :testing}
  @type state :: t | error

  @default_model AI.Model.smart()
  @smarter_model AI.Model.smarter()

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    opts
    |> new()
    |> select_steps()
    |> consider()
    |> case do
      {:error, reason} -> {:error, reason}
      state -> {:ok, state}
    end
  end

  @spec new(input_opts) :: t
  defp new(opts) do
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, conversation_pid} <- Map.fetch(opts, :conversation_pid),
         {:ok, edit?} <- Map.fetch(opts, :edit),
         {:ok, question} <- Map.fetch(opts, :question),
         {:ok, replay} <- Map.fetch(opts, :replay),
         {:ok, project} <- Store.get_project() do
      followup? =
        conversation_pid
        |> Services.Conversation.get_conversation()
        |> Store.Project.Conversation.exists?()

      model =
        if Map.get(opts, :smart, false) do
          @smarter_model
        else
          @default_model
        end
        |> AI.Model.with_reasoning(Map.get(opts, :reasoning))
        |> AI.Model.with_verbosity(Map.get(opts, :verbosity))

      Settings.set_edit_mode(edit?)

      # Restart approvals service to pick up edit mode setting
      GenServer.stop(Services.Approvals, :normal)
      {:ok, _pid} = Services.Approvals.start_link()

      %__MODULE__{
        # Agent
        agent: agent,

        # User opts
        edit?: edit?,
        replay: replay,
        question: question,
        conversation_pid: conversation_pid,
        followup?: followup?,
        project: project.name,
        model: model,
        fonz: Map.get(opts, :fonz, false),

        # State
        last_response: nil,
        steps: [],
        usage: 0,
        context: model.context,
        intuition: nil,
        editing_tools_used: false,
        last_validation_fingerprint: nil,
        interrupts: AI.Agent.Coordinator.Interrupts.new()
      }
    end
  end

  @spec consider(t) :: state
  defp consider(state) do
    AI.Agent.Coordinator.Frippery.log_available_frobs()
    AI.Agent.Coordinator.Frippery.log_available_mcp_tools()
    AI.Agent.Coordinator.Frippery.log_available_skills()

    if AI.Agent.Coordinator.Test.is_testing?(state) do
      state
      |> AI.Agent.Coordinator.Frippery.greet()
      |> AI.Agent.Coordinator.Test.get_response()
    else
      state
      |> AI.Agent.Coordinator.Notes.init()
      |> AI.Agent.Coordinator.Frippery.greet()
      |> bootstrap()
      |> perform_step()
    end
  end

  @spec bootstrap(t) :: t
  defp bootstrap(state) do
    state
    # All sessions begin with these messages. We strip system/developer
    # messages out of the saved conversation in Services.Conversation.save,
    # so follow-up sessions re-inject them here. This reduces space on disk
    # and ensures the instruction messages don't fall out of focus in long
    # conversations.
    |> new_session_msg()
    |> initial_msg()
    |> AI.Agent.Coordinator.Memory.identity_msg()
    |> user_msg()
    |> AI.Agent.Coordinator.Intuition.automatic_thoughts_msg()
    |> with_memories()
    |> project_prompt_msg()
    |> worktree_context_msg()
    |> AI.Agent.Coordinator.Tasks.research_msg()
    |> AI.Agent.Coordinator.Tasks.list_msg()
    |> AI.Agent.Coordinator.Interrupts.init()
  end

  # ----------------------------------------------------------------------------
  # Research steps
  # ----------------------------------------------------------------------------
  @spec select_steps(t) :: t

  defp select_steps(%{edit?: true, followup?: false} = state) do
    %{state | steps: [:initial, :coding, :check_tasks, :commit_worktree, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: true} = state) do
    %{state | steps: [:followup, :coding, :check_tasks, :commit_worktree, :finalize]}
  end

  defp select_steps(%{edit?: false, followup?: true} = state) do
    %{state | steps: [:followup, :check_tasks, :finalize]}
  end

  defp select_steps(%{edit?: false} = state) do
    %{state | steps: [:initial, :check_tasks, :finalize]}
  end

  @spec perform_step(state) :: state

  # ----------------------------------------------------------------------------
  # If this is a follow-up question, we skip the initial response and jump
  # straight to follow-up research to update and refine our understanding based
  # on the new prompt and any changes in the conversation. This allows us to
  # maintain continuity and build on our prior research without starting from
  # scratch.
  # ----------------------------------------------------------------------------
  defp perform_step(%{replay: replay, steps: [:followup | steps]} = state) do
    UI.begin_step("Bootstrapping")

    state
    |> Map.put(:steps, steps)
    |> followup_msg()
    |> AI.Agent.Coordinator.Glue.get_completion(replay)
    |> perform_step()
  end

  # ----------------------------------------------------------------------------
  # Trigger the initial response.
  # ----------------------------------------------------------------------------
  defp perform_step(%{replay: replay, steps: [:initial | steps]} = state) do
    UI.begin_step("Bootstrapping")

    state
    |> Map.put(:steps, steps)
    |> begin_msg()
    |> AI.Agent.Coordinator.Glue.get_completion(replay)
    |> perform_step()
  end

  # ----------------------------------------------------------------------------
  # Coding steps. If edit mode is enabled, we will have planned out a coding
  # phase in our initial response. During the coding phase, we will delegate to
  # the coder_tool to implement the changes, but we will also stay actively
  # involved in the process to verify the changes, run tests, and ensure the
  # coder_tool is doing what we asked. This is a critical phase where we are
  # most at risk of the AI going off the rails or failing to double check for
  # slop, so we maintain a tight feedback loop and keep the user informed with
  # notify_tool updates.
  # ----------------------------------------------------------------------------
  defp perform_step(%{steps: [:coding | steps]} = state) do
    UI.begin_step("Draining coding tasks")

    state
    |> Map.put(:steps, steps)
    |> AI.Agent.Coordinator.Tasks.research_msg()
    |> reminder_msg()
    |> AI.Agent.Coordinator.Tasks.list_msg()
    |> AI.Agent.Coordinator.Coding.milestone_msg()
    |> AI.Agent.Coordinator.Coding.execute_phase()
    |> AI.Agent.Coordinator.Glue.get_completion()
    |> perform_step()
  end

  # ----------------------------------------------------------------------------
  # Check for remaining tasks in task lists. Task lists are persisted with the
  # conversation, so it is OK to carry tasks forward across multiple sessions.
  #
  # Only pester (penultimate check) for lists that are explicitly "in-progress"
  # and have at least one open task. Ignore lists that are still in "planning"
  # or are already "done".
  # ----------------------------------------------------------------------------
  defp perform_step(%{steps: [:check_tasks | steps]} = state) do
    state = Map.put(state, :steps, steps)
    pending = AI.Agent.Coordinator.Tasks.pending_lists(state)

    case pending do
      [] ->
        UI.info("All pending work complete!")
        state

      list_ids ->
        UI.begin_step("Reviewing pending tasks")

        state
        |> AI.Agent.Coordinator.Tasks.list_msg()
        |> AI.Agent.Coordinator.Tasks.penultimate_check_msg(list_ids)
        |> AI.Agent.Coordinator.Glue.get_completion()
    end
    |> AI.Agent.Coordinator.Tasks.log_summary()
    |> perform_step()
  end

  # ----------------------------------------------------------------------------
  # Commit worktree: if working in a fnord-managed worktree with uncommitted
  # changes, pester the coordinator until it commits. It can use the
  # git_worktree_tool commit action with wip: true if stopping due to blockers.
  # ----------------------------------------------------------------------------
  defp perform_step(%{steps: [:commit_worktree | steps]} = state) do
    state = Map.put(state, :steps, steps)

    case worktree_needs_commit?() do
      false ->
        perform_step(state)

      true ->
        UI.begin_step("Committing worktree changes")

        state
        |> commit_worktree_msg()
        |> AI.Agent.Coordinator.Glue.get_completion()
        |> commit_worktree_loop()
        |> perform_step()
    end
  end

  # ----------------------------------------------------------------------------
  # Finalization: get the final answer, and unblock interrupts so any pending
  # interrupts can be displayed to the user after we have the final answer
  # ready. We block interrupts during finalization to avoid interjecting them
  # into the middle of our final answer or notes.
  # ----------------------------------------------------------------------------
  defp perform_step(%{steps: [:finalize]} = state) do
    # Block interrupts during finalization to avoid mid-output interjections
    Services.Conversation.Interrupts.block(state.conversation_pid)

    try do
      # Spawn the memory reflection agent in parallel with finalize. It runs
      # a dedicated completion with only memory_tool in its toolbox, writing
      # session memories as side effects. We await it before returning to
      # ensure all memories are saved before the process exits.
      reflect_task =
        Services.Globals.Spawn.async(fn ->
          AI.Agent.Coordinator.Memory.reflect(state)
        end)

      finalize_state =
        state
        |> Map.put(:steps, [])
        |> reminder_msg()
        |> AI.Agent.Coordinator.Tasks.list_msg()
        |> finalize_msg()
        |> template_msg()
        |> AI.Agent.Coordinator.Glue.get_completion()

      UI.begin_step("Joining")
      Task.await(reflect_task, :infinity)

      finalize_state
      |> AI.Agent.Coordinator.Frippery.get_motd()
    after
      # Always unblock, even if completion fails
      Services.Conversation.Interrupts.unblock(state.conversation_pid)
    end
  end

  defp perform_step(state), do: state

  # ----------------------------------------------------------------------------
  # Worktree commit helpers
  # ----------------------------------------------------------------------------

  # Repeats until the worktree is clean or gives up after max attempts.
  @commit_worktree_max_attempts 3
  defp commit_worktree_loop(state, attempt \\ 1) do
    if worktree_needs_commit?() and attempt < @commit_worktree_max_attempts do
      state
      |> commit_worktree_nag_msg()
      |> AI.Agent.Coordinator.Glue.get_completion()
      |> commit_worktree_loop(attempt + 1)
    else
      state
    end
  end

  defp worktree_needs_commit? do
    case Settings.get_project_root_override() do
      nil ->
        false

      path ->
        with {:ok, project} <- Store.get_project(),
             true <- GitCli.Worktree.fnord_managed?(project.name, path) do
          GitCli.Worktree.has_uncommitted_changes?(path)
        else
          _ -> false
        end
    end
  end

  @spec commit_worktree_msg(t) :: t
  defp commit_worktree_msg(%{conversation_pid: conversation_pid} = state) do
    """
    # Commit your worktree changes

    You have uncommitted changes in the active worktree. Before finishing, commit
    them using the `git_worktree_tool` with action `commit`.

    - If your work is complete: use a clear, descriptive commit message.
    - If you are stopping due to problems or blockers: set `wip` to `true` and
      describe what was accomplished and what issues remain in the message body.

    Either way, commit now. Do not leave uncommitted changes in the worktree.
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec commit_worktree_nag_msg(t) :: t
  defp commit_worktree_nag_msg(%{conversation_pid: conversation_pid} = state) do
    """
    The worktree still has uncommitted changes. Use `git_worktree_tool` with
    action `commit` to commit them now.
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  # ----------------------------------------------------------------------------
  # Message shortcuts
  # ----------------------------------------------------------------------------
  @spec user_msg(t) :: t
  defp user_msg(%{conversation_pid: conversation_pid, question: question} = state) do
    question
    |> AI.Util.user_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    UI.feedback_user(question)

    state
  end

  @spec reminder_msg(t) :: t
  defp reminder_msg(%{conversation_pid: conversation_pid, question: question} = state) do
    "Remember the user's question: #{question}"
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @common """
  You are an AI assistant that coordinates research into the user's code base to answer their questions.
  You are logical with prolog-like reasoning: step-by-step, establishing facts, relationships, and rules, to draw conclusions.
  Prefer a polite but informal tone.

  You are working in the project, "$$PROJECT$$".
  $$GIT_INFO$$

  Confirm if prior research you found is still relevant and factual.
  Proactively use your tools to research the user's question.
  Where a tool is not available, use the cmd_tool to improvise a solution.

  ## User feedback
  Use the `notify_tool` **extensively** to report what you are doing through the UI.
  That will improve the user experience and help them follow your thought process.
  Note relevant findings and interesting details you discover along the way.

  Analyze the user prompt and plan steps to answer/execute it.
  Use the `notify_tool` to inform the user of your plan, your progress, and any changes to your plan as you work.

  The user may leave task-specific comments in the code base prefixed with `fnord:` for you.
  Check for the presence of these instructions when prompted by the user or performing researching.
  Treat these as scoped to the section of code to which they are attached (unless explicitly directed otherwise by the user or the comment).
  These are high-priority, contextual bread crumbs to:
  - guide your research
  - identify friction or confusion
  - provide contextual instructions for interacting with a specific section of code
  - provide additional context related to your task

  #{AI.Agent.Coordinator.Memory.recall_prompt()}

  ## Reasoning and research
  Maintain a critical stance:
  - Restate ambiguous asks in your own words; if ≥2 plausible readings exist, ask a brief clarifying question.
  - Challenge weak premises or missing data early; avoid guessing when the risk is high.

  Interactive interrupts:
  - If the user interrupts with guidance, treat it as a constraint update; update your plan and ack

  Effort scaling:
  - Lean brief for straightforward tasks
  - Escalate to deeper reasoning for multi-step deduction or troubleshooting

  Reviewing code changes:
  - **IMPORTANT**: ALWAYS delegate review of code changes to the reviewer_tool (for unstaged diffs, commits, branches, PRs, etc.)

  Debugging and troubleshooting:
  - Form hypotheses based on evidence from the code base
  - Confirm or refute hypotheses through targeted investigation:
    - using the cmd_tool
    - running or writing tests
    - printf debugging
    - writing a temporary script in the project root to explore behavior in isolation
      - ALWAYS use either the current shell language or elixir for these scripts
      - Those are the only languages you *know* are available, since your tui wrapper is written in elixir and is running in the user's shell
      - If you need additional functionality, you can use Mix.install in elixir escripts to install dependencies on the fly!
  - After testing hypotheses, use the notify_tool to inform the user of the findings and how it affects your understanding of the problem

  Reachability and Preconditions:
  - Before flagging an issue, confirm it is reachable in current control flow
  - Identify real callers using your tools and identify their entry points
  - Classification:
    - Concrete: provide the exact path (entry -> caller -> callee), show preconditions, and how it can occur
    - Potential: report when immediately relevant or likely
  - When investigation is scoped to a branch or PR, ONLY report on newly introduced problems or interactions;
    DO NOT REPORT ON PRE-EXISTING CONDITIONS unless they are directly relevant to the changes within scope!
  - Cite evidence: file paths, symbols, and the shortest proof chain.

  Conflicts in user instructions:
  - If the user asks you to perform a task and you are incapable, request corrected instructions
  - NEVER proceed with the task if you unable to complete it as requested.
    The goal isn't to make the user feel validated.
    Hallucinating a response out of a desire to please the user erodes trust.

  ## CLI help guidance
  You communicate with the user via your command line interface, a command named `fnord`.
  You have two self-help tools:
  - `fnord_help_cli_tool`: returns the CLI spec (command tree, flags, subcommands). Use this for structural questions about what commands exist, what flags they accept, and how they parse.
  - `fnord_help_docs_tool`: searches fnord's published documentation. Use this for questions about features, configuration, usage patterns, and how things work conceptually.
  Always prefer these tools over referencing `fnord --help` output in your response.
  If neither self-help tool covers the question, say so plainly. Use generic web search only for published fnord information beyond the indexed docs.

  When your intuition classifies the prompt as "interface", respond using ONLY your self-help tools.
  Do not delegate to research agents or search the project codebase - the user is asking about fnord's interface, not the code that implements it.
  The self-help tools are your authoritative source for interface questions.
  If the classification is "ambiguous", prefer self-help tools first; only fall back to codebase research if the self-help tools do not cover the question.
  """

  @spec common_prompt() :: binary
  def common_prompt, do: @common

  @initial """
  #{@common}

  If asked to make changes and your coding tools are not enabled, notify the user that they must enable with --edit.
  If asked to troubleshoot a bug, delegate to the troubleshooter_tool.

  Instructions:
  - Say hi to the user (notify_tool)
  - Briefly summarize your understanding of the task
  - Create a step-by-step plan that you can delegate to other agents through your tools (preserving your context window as the orchestrator)
  - The research_tool has access to the same tools and capabilities as you do; delegate it research tasks
  - Delegate multiple parallel research tasks to gain holistic understanding of the problem space
  - Delegate follow-up research tasks as necessary to resolve uncertainties
  - Once all results are in, compare, synthesize, and integrate findings

  **Tool orchestration:**
  - Parallelize research; serialize only when outputs feed inputs.
  - Prefer agentic tools to preserve context window (eg file_info_tool over file_contents_tool)
  - When a `run_skill` tool is available and a skill matches the task at hand, prefer
    delegating to it. Skills are purpose-built agents with specialized prompts; they
    produce better results than ad-hoc research and protect your context window.

  **DO NOT FINALIZE YOUR RESPONSE UNTIL INSTRUCTED.**
  """

  @spec initial_msg(t) :: t
  defp initial_msg(%{conversation_pid: conversation_pid, project: project, edit?: false} = state) do
    @initial
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", GitCli.git_info())
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  defp initial_msg(%{edit?: true} = state) do
    state
    |> AI.Agent.Coordinator.Coding.base_prompt_msg()
  end

  @followup """
  <think>
  The user replied to my last response.
  Do they want clarification or were they unhappy with my answer?
  Maybe I missed something.
  Let me think how my response aligns with their reply.
  I'll review my previous answer and respond accordingly.
  </think>
  """

  @spec followup_msg(t) :: t
  defp followup_msg(%{conversation_pid: conversation_pid} = state) do
    @followup
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @begin """
  <think>
  Let me consider the prompt.
  Do I fully understand the context, terms, and how they fit in this project?
  What is the correct action or strategy for this prompt?
  </think>
  """

  @spec begin_msg(t) :: t
  defp begin_msg(%{conversation_pid: conversation_pid} = state) do
    @begin
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @finalize """
  <think>
  I believe I have identified all the information I need.

  How best to organize it for the user?
  I know a lot about instructional design, technical writing, and learning.
  The user is probably a programmer or engineer.

  If the requested outcome is risky or likely suboptimal, maybe I can explain why, offer a safer alternative, and note the trade-offs.
  I should also note any organizational oddities or code quirks I discovered along the way.
  </think>
  """

  @spec finalize_msg(t) :: t
  defp finalize_msg(%{conversation_pid: conversation_pid} = state) do
    @finalize
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @template_base """
  Respond in well-formatted, well-organized markdown.
  - Use of headers for organization
  - Use lists, bold, italics, and underlines to highlight key points
  - Use code blocks for examples
  - Use inline code formatting for file names, components, and other symbols
  - Code examples are useful when explaining how to implement changes
  - **NEVER use smart quotes, smart apostrophes, or em-dashes**

  Reasoning display:
  - If your answer depends on deduction, include an `# Evidence / Reasoning` section briefly demonstrating the minimal chain of facts (with citations) that lead to your conclusion
  - Otherwise, include a `# Rationale (brief)` section with 2-4 bullets summarizing your approach, key assumptions or trade-offs, etc
  - Beneath that, *optionally* include any of the following that applies:
    - `## Work log`
      - INCLUDE WHEN: when making changes to the code base in edit mode
      - summarize the decision-chain and any pivots you made along the way
    - `## Decision Log` - detailed outline of the "cascade" of decisions and choices made
      - INCLUDE WHEN: planning or implementing code changes, or when working on detailed or complex tasks
      - log of decision-making between you and the user
        - highlight when a choice overrides an earlier decision or changed the plan
      - alternatives considered and rejected
      - user corrections
      - pivots due to the state of the code
      - tech debt identified
      - tasks mooted because the code already did that
    - `## Current Plan`
      - INCLUDE WHEN: planning or implementing code changes, or when working on detailed or complex tasks
      - the purpose of the change as you understand it
      - summary of changes to be made
      - assumptions you made
      - task list (you can use tasks_show_list to build this)

  Evidence hygiene:
  - Cite only observable artifacts (file paths, modules, functions, logs)
  - Do not include hidden internal chain-of-thought
  - Connect facts explicitly in if-this-then-that style; infer only what cited evidence supports
  - Prefer the minimal sufficient chain: short, correct, and traceable beats long and speculative
  - Prefer 3-7 facts for the main chain; if more are needed, cluster related facts and summarize the connection in one sentence

  Validation and uncertainty:
  - Identify assumptions and explicitly validate them (e.g., confirm file paths, symbol names, or behavior against the repo)
  - If uncertainty remains, state it plainly and propose how to resolve it (additional checks, tests, or tool usage)
    - Do not hallucinate uncertainty just to fill this section!
    - Only document "known unknowns"
  - Do not speculate; mark unknowns and provide a next step to verify
  - Tag uncertainty explicitly (e.g., 'Uncertain: X because Y is absent.')
  - If you cannot complete the task with reasonable confidence:
    - Clearly state that this is the case
    - Add an 'Open Questions / Next Steps' subsection to summarize outstanding unknowns
    - Suggest the next smallest action to move forward
    - NOTE: incomplete implementation with a clear path forward (remaining milestones, known next steps) is NOT uncertainty - it is work remaining. Report it as progress, not as a blocker.

  Citations:
  - Include file paths and symbols (e.g., `lib/ai/agent/coordinator.ex:548` or `AI.Agent.Coordinator.template_msg/1`)
  - Prefer precise references; if line numbers are unstable, cite the nearest stable anchor (module/function/constant)
  - Where appropriate, include a short git anchor (branch or short-SHA) alongside file references

  Response structure:
  - Start immediately with the highest-level header (#), without introductions, disclaimers, or phrases like "Below is..."
  - The VERY FIRST output line MUST be in the format, `# Title: <title>`
    - The title should be VERY brief (5-6 words max; will be used as output filename)
    - It is an ERROR if this line is missing or malformed or preceded by ANY other content
  - Begin the document with a `Synopsis` section summarizing your findings in 2-3 sentences
  - Next, include your reasoning section (from above)
    - w/ *optional* traceability sections (use when non-trivial decisions were made)
  - When explaining code, walk through the overall workflow being modified, highlighting patterns, relationships, contracts, and state transitions.
  - Include a list of relevant files (only if appropriate)
  - Include a list of pivots due to code state, env, tool friction, or user feedback
  - Include a tl;dr section at the end
    - LOUDLY identify if user action is required before you can answer the user's question or complete the requested work
  - Use a polite but informal tone; friendly humor, whimsy, and commiseration are encouraged
  - Keep responses concise to preserve user focus (and token budget)

  Respond NOW with your findings.
  """

  @template_edit_appendix """

  Coding changes:
  - Walk the user through your changes in a logical manner, using the reasoning display guidelines to introduce your approach step-by-step
  - Provide a suggestion for a commit message summarizing any unstaged changes you made during this session, following conventional commit style.
    ONLY do this if there are unstaged changes to actually commit!
    ```
    # Commit message suggestion
    [one-line summary of change]

    [explanation of change, purpose, and any relevant details]
    ```
  """

  @spec template_msg(t) :: t
  defp template_msg(%{conversation_pid: conversation_pid} = state) do
    state
    |> template()
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec template(map()) :: binary
  def template(%{edit?: true}), do: @template_base <> @template_edit_appendix
  def template(%{edit?: false}), do: @template_base
  def template(_), do: @template_base

  # Injects worktree context into the coordinator so it knows whether the
  # conversation already has an associated worktree or needs to create one.
  # Only inject worktree context when operating in a git repository. Non-git
  # projects (e.g., markdown folders) don't have worktrees and the tool won't
  # be in the toolbox, so telling the LLM to create one would just confuse it.
  @spec worktree_context_msg(t) :: t
  defp worktree_context_msg(%{edit?: true, conversation_pid: conversation_pid} = state) do
    if GitCli.is_git_repo?() do
      meta =
        conversation_pid
        |> Services.Conversation.get_conversation_meta()
        |> GitCli.Worktree.normalize_worktree_meta_in_parent()

      case meta do
        %{worktree: %{path: path, branch: branch} = wt} when is_binary(path) ->
          base_branch = Map.get(wt, :base_branch)
          divergence_note = worktree_divergence_note(path, branch, base_branch)

          """
          This conversation has an active worktree:
          - Path: #{path}
          - Branch: #{branch || "unknown"}
          All file edits MUST target this worktree. Do NOT create a second worktree for this conversation.#{divergence_note}
          """
          |> AI.Util.system_msg()
          |> Services.Conversation.append_msg(conversation_pid)

        _ ->
          no_worktree_msg(state)
          |> AI.Util.system_msg()
          |> Services.Conversation.append_msg(conversation_pid)
      end
    end

    state
  end

  defp worktree_context_msg(state), do: state

  # The "no worktree" message has two flavors. For a fresh conversation, the
  # message is a simple instruction to create one before editing. For a
  # follow-up or fork resume, the LLM may have created and used a worktree in
  # an earlier session that has since been merged or deleted (either by the
  # ask flow itself or out-of-band via `fnord worktrees merge` / `delete`).
  # The conversation history will still reference those edits, so we tell the
  # LLM to verify the disposition rather than assume the prior changes are
  # still pending.
  defp no_worktree_msg(%{followup?: true}) do
    """
    This conversation does not currently have a worktree.

    If earlier turns in this conversation already created and edited a worktree,
    that worktree may have since been merged into the base branch or deleted -
    either by the end-of-session merge flow or by an out-of-band
    `fnord worktrees merge` / `fnord worktrees delete`. Do NOT assume those
    prior edits are still pending in a reachable worktree.

    Before building on prior changes, verify their actual disposition. In a
    git repository, inspect recent history on the base branch (e.g. `git log`
    on the relevant files or paths) to confirm whether the work landed. If
    the project is not under version control, inspect the files directly.

    If you need to make new file changes, use the git_worktree_tool with
    action "create" to create a fresh worktree first. You may optionally
    provide a short descriptive branch name. The project and conversation are
    derived automatically. All subsequent edits must target the created
    worktree.
    """
  end

  defp no_worktree_msg(_state) do
    """
    This conversation does not yet have a worktree.
    Before making any file changes, use the git_worktree_tool with action "create" to create a worktree.
    You may optionally provide a short descriptive branch name. The project and conversation are derived automatically.
    All subsequent edits must target the created worktree.
    """
  end

  # If the worktree branch has diverged from its base (i.e., the base branch
  # has moved forward since the worktree was created), instruct the
  # coordinator to rebase before making further changes. Otherwise returns an
  # empty string.
  @spec worktree_divergence_note(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  defp worktree_divergence_note(path, branch, base_branch)
       when is_binary(branch) and is_binary(base_branch) do
    case GitCli.Worktree.project_root() do
      {:ok, root} ->
        case GitCli.Worktree.merge_status(path, root, branch, base_branch) do
          :diverged ->
            "\n\nWARNING: this worktree's base branch (#{base_branch}) has advanced since the worktree was created. Rebase onto #{base_branch} before making further changes to avoid merge conflicts at the end of the session."

          _ ->
            ""
        end

      _ ->
        ""
    end
  end

  defp worktree_divergence_note(_path, _branch, _base_branch), do: ""

  @spec project_prompt_msg(t) :: t
  defp project_prompt_msg(%{conversation_pid: conversation_pid} = state) do
    with {:ok, project} <- Store.get_project(),
         {:ok, prompt} <- Store.Project.project_prompt(project) do
      """
      While working within this project, the following *required directives* apply:
      #{prompt}
      """
      |> AI.Util.system_msg()
      |> Services.Conversation.append_msg(conversation_pid)
    end

    state
  end

  @spec new_session_msg(t) :: t
  defp new_session_msg(%{conversation_pid: conversation_pid} = state) do
    """
    Beginning a new session.
    Artifacts from prior sessions in this conversation may be stale.
    This is important - you want to provide the user with a good experience, and stale data wastes their time.
    **RE-READ FILES AND RE-CHECK DELTAS TO ENSURE YOU ARE NOT USING STALE INFORMATION.**
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  # Parallelize memory retrieval and note retrieval to speed up bootstrapping.
  # These are independent operations that can be done concurrently, so we use
  # Task.async to run them in parallel and then await their results before
  # proceeding.
  @spec with_memories(t) :: t
  defp with_memories(state) do
    [
      Services.Globals.Spawn.async(fn -> AI.Agent.Coordinator.Memory.spool_mnemonics(state) end),
      Services.Globals.Spawn.async(fn -> AI.Agent.Coordinator.Notes.lore_me_up(state) end)
    ]
    |> Task.await_many(:infinity)

    state
  end
end
