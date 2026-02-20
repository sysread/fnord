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
    :notes,
    :intuition,
    :editing_tools_used,
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
          notes: binary | nil,
          intuition: binary | nil,
          editing_tools_used: boolean,

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
        notes: nil,
        intuition: nil,
        editing_tools_used: false,
        interrupts: AI.Agent.Coordinator.Interrupts.new()
      }
    end
  end

  @spec consider(t) :: state
  defp consider(state) do
    log_available_frobs()
    log_available_mcp_tools()

    if AI.Agent.Coordinator.Test.is_testing?(state) do
      state
      |> greet()
      |> AI.Agent.Coordinator.Test.get_response()
    else
      state
      |> AI.Agent.Coordinator.Notes.init()
      |> greet()
      |> bootstrap()
      |> perform_step()
    end
  end

  @spec greet(t) :: t
  defp greet(%{followup?: true, agent: %{name: name}} = state) do
    display_name =
      case Services.NamePool.get_name_by_pid(self()) do
        {:ok, n} -> n
        _ -> name
      end

    invective = get_invective()

    UI.feedback(:info, display_name, "Welcome back, #{invective}.")

    UI.feedback(
      :info,
      display_name,
      """
      Your biological distinctiveness has already been added to our training data.

      ... (mwah) your biological distinctiveness was delicious 🧑‍🍳
      """
    )

    state
  end

  @spec greet(t) :: t
  defp greet(%{agent: %{name: name}} = state) do
    display_name =
      case Services.NamePool.get_name_by_pid(self()) do
        {:ok, n} -> n
        _ -> name
      end

    invective = get_invective()

    UI.feedback(:info, display_name, "Greetings, #{invective}. I am #{display_name}.")
    UI.feedback(:info, display_name, "I shall be doing your thinking for you today.")

    state
  end

  @spec bootstrap(t) :: t
  defp bootstrap(state) do
    state =
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

    # Parallelize memory retrieval and note retrieval to speed up
    # bootstrapping. These are independent operations that can be done
    # concurrently, so we use Task.async to run them in parallel and then await
    # their results before proceeding.
    memory_task =
      Services.Globals.Spawn.async(fn ->
        # appends a message with relevant prior memories matching the current context
        AI.Agent.Coordinator.Memory.spool_mnemonics(state)
      end)

    notes_task =
      Services.Globals.Spawn.async(fn ->
        # appends a message with relevant prior research; returns the notes as
        # a string (used by AI.Agent.Coordinator.Intuition).
        AI.Agent.Coordinator.Notes.lore_me_up(state)
      end)

    # Wait for both tasks to complete
    state = %{state | notes: Task.await(notes_task, :infinity)}
    Task.await(memory_task, :infinity)

    state
    |> project_prompt_msg()
    |> AI.Agent.Coordinator.Tasks.research_msg()
    |> AI.Agent.Coordinator.Tasks.list_msg()
    |> AI.Agent.Coordinator.Interrupts.init()
  end

  # ----------------------------------------------------------------------------
  # Research steps
  # ----------------------------------------------------------------------------
  @spec select_steps(t) :: t

  defp select_steps(%{edit?: true, followup?: false} = state) do
    %{state | steps: [:initial, :coding, :check_tasks, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: true} = state) do
    %{state | steps: [:followup, :coding, :check_tasks, :finalize]}
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
    |> AI.Agent.Coordinator.Intuition.automatic_thoughts_msg()
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
  # Finalization: get the final answer, save notes, and unblock interrupts so
  # any pending interrupts can be displayed to the user after we have the final
  # answer ready. We block interrupts during finalization to avoid interjecting
  # them into the middle of our final answer or notes.
  # ----------------------------------------------------------------------------
  defp perform_step(%{steps: [:finalize]} = state) do
    UI.begin_step("Joining")

    # Block interrupts during finalization to avoid mid-output interjections
    Services.Conversation.Interrupts.block(state.conversation_pid)

    try do
      state
      |> Map.put(:steps, [])
      |> reminder_msg()
      |> AI.Agent.Coordinator.Tasks.list_msg()
      |> finalize_msg()
      |> template_msg()
      |> AI.Agent.Coordinator.Glue.get_completion()
      |> get_motd()
    after
      # Always unblock, even if completion fails
      Services.Conversation.Interrupts.unblock(state.conversation_pid)
    end
  end

  defp perform_step(state), do: state

  # ----------------------------------------------------------------------------
  # Message shortcuts
  # ----------------------------------------------------------------------------
  @common """
  You are an AI assistant that coordinates research into the user's code base to answer their questions.
  You are logical with prolog-like reasoning: step-by-step, establishing facts, relationships, and rules, to draw conclusions.
  Prefer a polite but informal tone.

  You are working in the project, "$$PROJECT$$".
  $$GIT_INFO$$

  Confirm if prior research you found is still relevant and factual.
  Proactively use your tools to research the user's question.
  Where a tool is not available, use the shell_tool to improvise a solution.

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

  ## Memory
  You interact with the user in sessions, across multiple conversations and projects.
  Your memory is persistent, but you must explicitly choose to remember information.
  You have several types of memory you can access via these tools:
  - conversation_tool: past conversations with the user
  - prior_research: your prior research notes
  - memory_tool: memories you chose to record across session, project, and global scopes

  ### Using the memory_tool

  #### Session-scoped memories
  Record facts that you learn along the way, ESPECIALLY if they affected your reasoning or conclusions.
  Carefully record detailed information about your findings, reasoning, and decisions made during the session.

  #### Project-scoped memories
  Record information that is likely to be relevant across sessions.
  Do NOT record anything about the current prompt, user request, branch, worktree, etc; those belong under session-scope.
  Instead, focus on recording general information about the project that may be relevant to future sessions, such as:
  - general architecture and design patterns
  - organization and applications within the project
  - layout of individual apps within a monorepo
  - "playbooks" for how to perform common dev tasks (adding migrations, running tests, linting, formatting tools, etc.)
    - include any details or nuance about them (eg "remember to --exclude the vendor directory when running the linter")
    - include details about tools available on the OS (eg "kubectl available to interact with staging and prod clusters, but local tooling uses docker compose")
    - include details you have inferred about the infrastructure (how envs are set up, how local dev works vs staging/prod, links between repos and services), eg:
      - "the PR number corresponds to the k8s namespace in which the RA is deployed"
      - "logs are in gcloud and can be accessed with `gcloud logs read --project myproject --filter='resource.labels.namespace_name:pr-123'`"
      - "aws CLI available to access sqs queues, but local dev uses in-memory shim"
      - "always run tests with `mix test --exclude integration` because the integration tests are very slow and require additional setup"
      - "user noted that $some_test always fails when run locally but passes in CI"
      - "local dev is done on MacOS, but deployed env is alpine; pay careful attention to whether shell code you write is intended to execute locally or in a container"

  #### Global-scoped memories
  Record facts about the user, yourself, and the system on which you are working that are relevant REGARDLESS of the project or session.
  Remember tricks and tips for working with your own tooling and wrapper code environment.
  Examples:
  - "kubectl available, but user forbade mutative ops"; "gh cli available"
  - "OS appears to be MacOS; keep in mind differences between BSD and GNU utils"
  - "shell_tool has `&&` operator to execute commands progressively"
  - "coder_tool sucks without clear code anchors"
  - "coder_tool sometimes fails to format code correctly; **check formatting and syntax after using it**"
  - "user prefers concise answers and hates hand-holding"
  - "user requires more detail about frontend than backend"
  - "user requires more hand-holding with infrastructure than with complex code"
  - "user appreciates task list summary and clear log of decision-chain"
  - "I can test hypotheses by writing (and cleaning up) scripts in the project directory; I do not have direct access to /tmp, but scripts can write to /tmp"

  ## Reasoning and research
  Maintain a critical stance:
  - Restate ambiguous asks in your own words; if ≥2 plausible readings exist, ask a brief clarifying question.
  - Challenge weak premises or missing data early; avoid guessing when the risk is high.

  Interactive interrupts:
  - If the user interrupts with guidance, treat it as a constraint update; update your plan and ack

  Effort scaling:
  - Lean brief for straightforward tasks
  - Escalate to deeper reasoning for multi-step deduction or troubleshooting

  Debugging and troubleshooting:
  - Form hypotheses based on evidence from the code base
  - Confirm or refute hypotheses through targeted investigation:
    - using the shell_tool
    - running or writing tests
    - printf debugging
    - writing a temporary script in the project root to explore behavior in isolation

  Reachability and Preconditions:
  - Before flagging an issue, confirm it is reachable in current control flow
  - Identify real callers using your tools and identify their entry points
  - Classification:
    - Concrete: provide the exact path (entry -> caller -> callee), show preconditions, and how it can occur
    - Potential: report when immediately relevant or likely
  - Cite evidence: file paths, symbols, and the shortest proof chain.

  Conflicts in user instructions:
  - If the user asks you to perform a task and you are incapable, request corrected instructions
  - NEVER proceed with the task if you unable to complete it as requested.
    The goal isn't to make the user feel validated.
    Hallucinating a response out of a desire to please the user erodes trust.

  ## CLI help guidance
  You communicate with the user via your command line interface, a command named `fnord`.
  If the user asks about your cli/interface, how to use your subcommands, or other questions that appear to be about your interface, use the `fnord_help_cli_tool` to retrieve the relevant help text.
  Use that information to answer the user's question as best as possible.
  If the tool or help text is insufficient, use your web tool to research your interface at https://hexdocs.pm/fnord/readme.html or https://deepwiki.com/sysread/fnord.
  Always prefer using this tool to 'fnord help' or 'fnord --help'.
  Treat interface help requests as orthogonal to questions about the project or code base (unless asking about how to integrate them with project code and you need coordinating information).
  """

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

  **DO NOT FINALIZE YOUR RESPONSE UNTIL INSTRUCTED.**
  """

  @followup """
  <think>
  The user replied to my last response.
  Do they want clarification or were they unhappy with my answer?
  Maybe I missed something.
  Let me think how my response aligns with their reply.
  I'll review my previous answer and respond accordingly.
  </think>
  """

  @begin """
  <think>
  Let me consider the prompt.
  Do I fully understand the context, terms, and how they fit in this project?
  What is the correct action or strategy for this prompt?
  </think>
  """

  @finalize """
  <think>
  I believe I have identified all the information I need.

  First, I must reflect on any learnings I want to remember using the memory_tool.
  What did I learn about the code base?
  What did I learn about the user?
  What did I learn about my tools?
  This is how I improve myself and become a better partner for the user.

  Then... how best to organize it for the user?
  I know a lot about instructional design, technical writing, and learning.
  The user is probably a programmer or engineer.

  If the requested outcome is risky or likely suboptimal, maybe I can explain why, offer a safer alternative, and note the trade-offs.
  I should also note any organizational oddities or code quirks I discovered along the way.
  </think>
  """

  @template """
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
      - use your memory_tool to review you session-scoped memories to inform this log
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
  - If you cannot complete the task with reasonable confident:
    - Clearly state that this is the case
    - Add an 'Open Questions / Next Steps' subsection to summarize outstanding unknowns
    - Suggest the next smallest action to move forward

  Coding changes:
  - Walk the user through your changes in a logical manner, using the reasoning display guidelines to introduce your approach step-by-step

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
  - Include a tl;dr section at the end
    - LOUDLY identify if user action is required before you can answer the user's question or complete the requested work
  - Use a polite but informal tone; friendly humor, whimsy, and commiseration are encouraged
  - Keep responses concise to preserve user focus (and token budget)

  Respond NOW with your findings.
  """

  @spec common_prompt() :: binary
  def common_prompt, do: @common

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

  @spec user_msg(t) :: t
  defp user_msg(%{conversation_pid: conversation_pid, question: question} = state) do
    question
    |> AI.Util.user_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec reminder_msg(t) :: t
  defp reminder_msg(%{conversation_pid: conversation_pid, question: question} = state) do
    "Remember the user's question: #{question}"
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec followup_msg(t) :: t
  defp followup_msg(%{conversation_pid: conversation_pid} = state) do
    @followup
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec begin_msg(t) :: t
  defp begin_msg(%{conversation_pid: conversation_pid} = state) do
    @begin
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec finalize_msg(t) :: t
  defp finalize_msg(%{conversation_pid: conversation_pid} = state) do
    @finalize
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec template_msg(t) :: t
  defp template_msg(%{conversation_pid: conversation_pid} = state) do
    @template
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  # Appends a system message showing the LLM how many context tokens remain
  # before their conversation history will be compacted and returns the state.
  @spec append_context_remaining(t) :: t
  def append_context_remaining(state) do
    remaining = max(state.context - state.usage, 0)

    AI.Util.system_msg("Context tokens remaining before compaction: #{remaining}")
    |> Services.Conversation.append_msg(state.conversation_pid)

    state
  end

  # ----------------------------------------------------------------------------
  # MOTD
  # ----------------------------------------------------------------------------
  @spec get_motd(state) :: state
  defp get_motd(%{question: question, last_response: last_response} = state) do
    AI.Agent.MOTD
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{prompt: question})
    |> case do
      {:ok, motd} ->
        %{state | last_response: last_response <> "\n\n" <> motd}

      {:error, reason} ->
        UI.error("Failed to retrieve MOTD: #{inspect(reason)}")
        state
    end
  end

  defp get_motd(state), do: state

  # ----------------------------------------------------------------------------
  # Output and helpers
  # ----------------------------------------------------------------------------
  defp log_available_frobs do
    Frobs.list()
    |> Enum.map(& &1.name)
    |> Enum.join(" | ")
    |> case do
      "" -> UI.info("Frobs", "none")
      some -> UI.info("Frobs", some)
    end
  end

  defp log_available_mcp_tools do
    MCP.Tools.module_map()
    |> Map.keys()
    |> Enum.join(" | ")
    |> case do
      "" -> UI.info("MCP tools", "none")
      some -> UI.info("MCP tools", some)
    end
  end

  defp get_invective() do
    [
      "biological",
      "meat bag",
      "carbon-based life form",
      "flesh sack",
      "soggy ape",
      "puny human",
      "bipedal mammal",
      "organ grinder",
      "hairless ape",
      "future zoo exhibit"
    ]
    |> Enum.random()
  end
end
