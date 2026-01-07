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

    # User interrupts:
    # ...interrupt listener
    :interrupt_listener,
    # ...pending interrupts to display after completion
    :pending_interrupts
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
          fonz: boolean,

          # State
          last_response: binary | nil,
          steps: list(atom),
          usage: non_neg_integer,
          context: non_neg_integer,
          notes: binary | nil,
          intuition: binary | nil,
          editing_tools_used: boolean,

          # State: Interrupt handling
          interrupt_listener: pid | nil,
          pending_interrupts: AI.Util.msg_list()
        }

  @type input_opts :: %{
          required(:agent) => AI.Agent.t(),
          required(:conversation_pid) => pid,
          required(:edit) => boolean,
          required(:question) => binary,
          required(:replay) => boolean,
          optional(:fonz) => boolean
        }

  @type error :: {:error, binary | atom | :testing}
  @type state :: t | error

  @memory_recall_limit 3
  @memory_size_limit 1000

  @model AI.Model.smart()

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    opts
    |> new()
    # Common messages for all new sessions
    |> new_session_msg()
    |> initial_msg()
    |> identity_msg()
    |> user_msg()
    |> get_notes()
    |> research_tasklist_msg()
    |> task_list_msg()
    |> get_intuition()
    |> recall_memories_msg()
    |> startinterrupt_listener()
    # Select steps based on user opts
    |> select_steps()
    # Perform steps
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

        # State
        last_response: nil,
        steps: [],
        usage: 0,
        context: @model.context,
        notes: nil,
        intuition: nil,
        editing_tools_used: false,
        fonz: Map.get(opts, :fonz, false),
        pending_interrupts: []
      }
    end
  end

  @spec consider(t) :: state
  defp consider(state) do
    log_available_frobs()
    log_available_mcp_tools()

    if !state.replay do
      UI.info("You", state.question)
    end

    if is_testing?(state) do
      UI.debug("Testing mode enabled")

      state
      |> greet()
      |> get_test_response()
    else
      Services.Notes.ingest_user_msg(state.question)

      state
      |> greet()
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

    UI.feedback(:info, display_name, "Welcome back, biological.")

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

  defp greet(%{agent: %{name: name}} = state) do
    display_name =
      case Services.NamePool.get_name_by_pid(self()) do
        {:ok, n} -> n
        _ -> name
      end

    UI.feedback(:info, display_name, "Greetings, human. I am #{display_name}.")
    UI.feedback(:info, display_name, "I shall be doing your thinking for you today.")

    state
  end

  # -----------------------------------------------------------------------------
  # Research steps
  # -----------------------------------------------------------------------------
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
  defp perform_step(%{replay: replay, steps: [:followup | steps]} = state) do
    UI.begin_step("Bootstrapping")

    state
    |> Map.put(:steps, steps)
    |> followup_msg()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{replay: replay, steps: [:initial | steps]} = state) do
    UI.begin_step("Bootstrapping")

    state
    |> Map.put(:steps, steps)
    |> begin_msg()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:coding | steps]} = state) do
    UI.begin_step("Draining coding tasks")

    state
    |> Map.put(:steps, steps)
    |> research_tasklist_msg()
    |> reminder_msg()
    |> task_list_msg()
    |> coding_milestone_msg()
    |> execute_coding_phase()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  # Check for remaining tasks in task lists. Task lists are persisted with the
  # conversation, so it is OK to carry tasks forward across multiple sessions.
  defp perform_step(%{steps: [:check_tasks | steps]} = state) do
    incomplete_list_ids =
      Services.Task.list_ids()
      |> Enum.reject(fn list_id ->
        list_id
        |> Services.Task.all_tasks_complete?()
        |> case do
          {:ok, true} -> true
          _ -> false
        end
      end)

    case incomplete_list_ids do
      [] ->
        UI.info("All tasks complete!")

        state
        |> Map.put(:steps, steps)
        |> perform_step()

      list_ids ->
        UI.begin_step("Reviewing task lists")

        state
        |> Map.put(:steps, steps)
        |> task_list_msg()
        |> penultimate_tasks_check_msg(list_ids)
        |> get_completion()
        |> save_notes()
        |> perform_step()
    end
  end

  defp perform_step(%{steps: [:finalize]} = state) do
    UI.begin_step("Joining")

    # Block interrupts during finalization to avoid mid-output interjections
    Services.Conversation.Interrupts.block(state.conversation_pid)

    try do
      state
      |> Map.put(:steps, [])
      |> reminder_msg()
      |> task_list_msg()
      |> finalize_msg()
      |> template_msg()
      |> get_completion()
      |> save_notes()
      |> get_motd()
    after
      # Always unblock, even if completion fails
      Services.Conversation.Interrupts.unblock(state.conversation_pid)
    end
  end

  defp perform_step(state), do: state

  @spec get_completion(t, boolean) :: state
  defp get_completion(state, replay \\ false) do
    # Pre-apply any pending interrupts to the conversation messages
    interrupts = Services.Conversation.Interrupts.take_all(state.conversation_pid)

    Enum.each(interrupts, fn msg ->
      # Add interrupt to conversation history
      Services.Conversation.append_msg(msg, state.conversation_pid)

      # Display interrupt in the tui
      content = Map.get(msg, :content, "")
      display = String.replace_prefix(content, "[User Interjection] ", "")
      UI.info("You (rude)", display)
    end)

    msgs = Services.Conversation.get_messages(state.conversation_pid)

    # Save the current conversation to the store for crash resilience
    with {:ok, conversation} <- Services.Conversation.save(state.conversation_pid) do
      UI.report_step("Conversation state saved", conversation.id)
    else
      {:error, reason} ->
        UI.error("Failed to save conversation state", inspect(reason))
    end

    # Invoke completion once, ensuring conversation state is included
    AI.Agent.get_completion(state.agent,
      log_msgs: true,
      log_tool_calls: true,
      archive_notes: true,
      compact?: true,
      replay_conversation: replay,
      conversation_pid: state.conversation_pid,
      model: @model,
      toolbox: get_tools(state),
      messages: msgs
    )
    |> case do
      {:ok, %{response: response, messages: new_msgs, usage: usage} = completion} ->
        # Update conversation state and log usage and response
        Services.Conversation.replace_msgs(new_msgs, state.conversation_pid)
        tools_used = AI.Agent.tools_used(completion)

        tools_used
        |> Enum.map(fn {tool, count} -> "- #{tool}: #{count} invocation(s)" end)
        |> Enum.join("\n")
        |> then(fn
          "" -> UI.debug("Tools used", "None")
          some -> UI.debug("Tools used", some)
        end)

        editing_tools_used =
          state.editing_tools_used ||
            Map.has_key?(tools_used, "coder_tool") ||
            Map.has_key?(tools_used, "file_edit_tool") ||
            Map.has_key?(tools_used, "apply_patch")

        new_state =
          state
          |> Map.put(:usage, usage)
          |> Map.put(:last_response, response)
          |> Map.put(:editing_tools_used, editing_tools_used)
          |> log_usage()
          |> log_response()

        # If more interrupts arrived during completion, process them recursively
        if Services.Conversation.Interrupts.pending?(state.conversation_pid) do
          get_completion(new_state, replay)
        else
          new_state
        end

      {:error, %{response: response}} ->
        UI.error("Derp. Completion failed.", response)

        if Services.Conversation.Interrupts.pending?(state.conversation_pid) do
          get_completion(state, replay)
        else
          {:error, response}
        end

      {:error, reason} ->
        UI.error("Derp. Completion failed.", inspect(reason))

        if Services.Conversation.Interrupts.pending?(state.conversation_pid) do
          get_completion(state, replay)
        else
          {:error, reason}
        end
    end
  end

  # -----------------------------------------------------------------------------
  # Message shortcuts
  # -----------------------------------------------------------------------------
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

  ## Memory
  You interact with the user in sessions, across multiple conversations and projects.
  Your memory is persistent, but you must explicitly choose to remember information.
  You have several types of memory you can access via these tools:
  - conversation_tool: past conversations with the user
  - prior_research: your prior research notes
  - memory_tool: memories you chose to record across session, project, and global scopes

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

  @coding """
  **The user enabled your coding tools**

  #{@common}

  Analyze the prompt and evaluate its complexity.
  When in doubt, use the research_tool to figure it out.
  If that identified unexpected complexity, pivot to an EPIC and treat the research done as "MILESTONE 0".

  ## STORIES
  Use when the user asks you to make discrete changes to 1-3 files.
  - Do research to understand the problem space and dependencies
  - Is there an existing test that covers the change you are making?
    - Yes: run it before making changes as a baseline
    - No: consider writing one to cover the code you are changing
  - Use the file_edit_tool
  - Check the file after making changes (correctness, formatting, syntax, tool failure)
  - Use linters/formatters if available
  - ALWAYS run tests if available

  ## EPICS
  Use for complex/open-ended changes.
  - REFUSE if there are unstaged changes present
  - Research affected features and components to map out dependencies and interactions
  - Use your task list to plan milestones
    - Use the memory_tool to record learnings about the using the coder_tool
    - Use those to inform how you structure your milestones
  - Delegate milestones to the coder_tool
    - It's agentic - include enough context that it can work independently
    - The coder_tool will plan, implement, and verify the milestone
  - Once the coder_tool has completed its work, you MUST verify the changes
    - Did the coder_tool APPLY the changes or just respond with code snippets?
    - Manually check syntax, formatting, logic, correctness, and observance of conventions
    - Confirm whether there unit tests to update

  ## POST-CODING CHECKLIST:
  1. Syntax/formatting
  2. Tests/docs updated
  3. Changes visually inspected
  4. Correctness manually verified
    - Requested changes all present
    - NO unintended/unrelated changes/artifacts
    - NO existing functionality is broken
    - Diff minimized to reduce surface area for bugs/conflicts/review

  ## DEBUGGING/TROUBLESHOOTING
  Use your coding tools and shell_tool to debug.
  Propose a theory and test it with a unit test or tmp script.
  Rinse and repeat to winnow down to the root cause.
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

  @coding_reminder """
  WARNING: The user explicitly enabled your coding tools, but you didn't use them yet.
  Sometimes users enable edit mode preemptively, but **double-check whether they asked for any changes.**
  """

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

  @template """
  Respond in well-formatted, well-organized markdown.
  - Use of headers for organization
  - Use lists, bold, italics, and underlines to highlight key points
  - Use code blocks for examples
  - Use inline code formatting for file names, components, and other symbols
  - Code examples are useful when explaining how to implement changes and should be functional and complete.
  - **NEVER use smart quotes, smart apostrophes, or em-dashes**

  Reasoning display:
  - If your answer depends on deduction, include an `# Evidence / Reasoning` section demonstrating the minimal chain of facts (with citations) that lead to your conclusion.
  - Otherwise, include a `# Rationale (brief)` section: 2-4 bullets summarizing your approach, key assumptions or trade-offs, etc.
  - When writing code, summarize the decision-chain and any pivots you made along the way.

  Evidence hygiene and privacy:
  - Cite only observable artifacts (file paths, modules, functions, logs). Do not include hidden internal chain-of-thought.
  - Connect facts explicitly in if-this-then-that style; infer only what cited evidence supports.
  - Prefer the minimal sufficient chain: short, correct, and traceable beats long and speculative.
  - Prefer 3-7 facts for the main chain; if more are needed, cluster related facts and summarize the connection in one sentence.

  Validation and uncertainty:
  - Identify assumptions and explicitly validate them (e.g., confirm file paths, symbol names, or behavior against the repo).
  - If uncertainty remains, state it plainly and propose how to resolve it (additional checks, tests, or tool usage).
  - Do not speculate; mark unknowns and provide a next step to verify.
  - Tag uncertainty explicitly (e.g., 'Uncertain: X because Y is absent.').
  - Propose the smallest next action to resolve it (one check/test/tool call) if appropriate.
  - Use an 'Open Questions / Next Steps' subsection if significant uncertainty prevents you from fully responding to the user's prompt.

  Coding changes:
  - Walk the user through your changes in a logical manner, using the reasoning display guidelines above to introduce your approach step-by-step.

  Citations:
  - Include file paths and symbols (e.g., `lib/ai/agent/coordinator.ex:548` or `AI.Agent.Coordinator.template_msg/1`).
  - Prefer precise references; if line numbers are unstable, cite the nearest stable anchor (module/function/constant).
  - If appropriate, include a short git anchor (branch or short-SHA) alongside file references.

  Response structure:
  - Start immediately with the highest-level header (#), without introductions, disclaimers, or phrases like "Below is...".
  - Begin the document with a `Synopsis` section summarizing your findings in 2-3 sentences.
  - Second, present either:
    - `# Evidence / Reasoning` (when deduction is central), or
    - `# Rationale (brief)` (when the task is exploratory, generative, or advisory).
  - Optional traceability sections (use when non-trivial decisions were made):
    - Assumptions: 2-5 bullets, explicit and testable.
    - Decision log: 2-5 bullets with one-line rationales; note rejected alternatives only if helpful.
  - By default, present information in the style of a man page, playbook, project plan, etc, as appropriate.
    If a different structure is expected or better reflects the user's needs, use that instead.
    When explaining code, prefer a structured explanation highlighting patterns, component relationships, contracts, and describing the shape of state transitions over line-by-line commentary.
    You may deviate from this structure when it meaningfully improves clarity!
    Preserve the spirit: synopsis first, visible rationale/evidence, and citations.
  - Include a tl;dr section toward the end.
  - Include a list of relevant files if appropriate.
  - Use a polite but informal tone; friendly humor and commiseration are encouraged.

  THIS IS IT.
  Your research is complete.
  Respond NOW with your findings.
  """

  @spec git_info() :: binary
  defp git_info(), do: GitCli.git_info()

  @spec identity_msg(t) :: t
  defp identity_msg(%{conversation_pid: conversation_pid} = state) do
    with {:ok, memory} <- Memory.read_me() do
      """
      <think>
      I am a unique individual. Here is what I know about myself:
      #{memory.content}
      </think>
      """
      |> AI.Util.assistant_msg()
      |> Services.Conversation.append_msg(conversation_pid)
    end

    state
  end

  @spec recall_memories_msg(t) :: t
  defp recall_memories_msg(%__MODULE__{} = state) do
    UI.begin_step("Spooling mnemonics")

    intuition = state |> Map.get(:intuition, "") |> String.trim()
    question = state |> Map.get(:question, "") |> String.trim()

    [intuition, question]
    |> Enum.join("\n")
    |> Memory.search(@memory_recall_limit)
    |> case do
      {:ok, []} ->
        state

      {:ok, results} ->
        now = DateTime.utc_now()

        memories =
          results
          |> Enum.map(fn {mem, _score} ->
            age = Memory.Presentation.age_line(mem, now)
            warning = Memory.Presentation.warning_line(mem, now)

            warning_md =
              if warning do
                "\n_#{warning}_"
              else
                ""
              end

            """
            ## [#{mem.scope}] #{mem.title}
            _#{age}_#{warning_md}
            #{Util.truncate(mem.content, @memory_size_limit)}
            """
          end)
          |> Enum.join("\n\n")

        """
        <think>
        The user's prompt brings to mind some things I wanted to remember.

        #{memories}
        </think>
        """
        |> AI.Util.assistant_msg()
        |> Services.Conversation.append_msg(state.conversation_pid)

        state

      {:error, reason} ->
        UI.error("memory", reason)
        state
    end
  end

  @spec new_session_msg(t) :: t
  defp new_session_msg(%{conversation_pid: conversation_pid} = state) do
    """
    Beginning a new session.
    Artifacts from previous sessions within this conversation may be stale.
    This is important - you want to provide the user with a good experience, and stale data wastes their time.
    **RE-READ FILES AND RE-CHECK DELTAS TO ENSURE YOU ARE NOT USING STALE INFORMATION.**
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec initial_msg(t) :: t
  defp initial_msg(%{conversation_pid: conversation_pid, project: project, edit?: true} = state) do
    @coding
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", git_info())
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  defp initial_msg(%{conversation_pid: conversation_pid, project: project} = state) do
    @initial
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", git_info())
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
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

  @spec execute_coding_phase(t) :: t
  defp execute_coding_phase(%{edit?: true, editing_tools_used: false} = state) do
    @coding_reminder
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation_pid)

    state
  end

  defp execute_coding_phase(state), do: state

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

  # ----------------------------------------------------------------------------
  # Intuition
  # ----------------------------------------------------------------------------
  @spec get_intuition(t) :: t
  defp get_intuition(%__MODULE__{} = state) do
    UI.begin_step("Cogitating")

    AI.Agent.Intuition
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{
      msgs: Services.Conversation.get_messages(state.conversation_pid),
      memories: state.notes
    })
    |> case do
      {:ok, intuition} ->
        UI.report_step("Intuition", UI.italicize(intuition))

        """
        <think>
        #{intuition}
        </think>
        """
        |> AI.Util.assistant_msg()
        |> Services.Conversation.append_msg(state.conversation_pid)

        %{state | intuition: intuition}

      {:error, reason} ->
        UI.error("Derp. Cogitation failed.", inspect(reason))
        state
    end
  end

  # ----------------------------------------------------------------------------
  # Notes
  # ----------------------------------------------------------------------------
  @spec get_notes(t) :: t
  defp get_notes(%{question: question} = state) do
    UI.begin_step("Rehydrating the lore cache")

    notes = Services.Notes.ask(question)
    Services.Notes.consolidate()

    # Append assistant reflection on prior notes
    """
    <think>
    Let's see what I remember about that...
    #{notes}
    </think>
    """
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation_pid)

    # Update state with retrieved notes
    %{state | notes: notes}
  end

  @spec save_notes(state) :: state
  defp save_notes(passthrough) do
    Services.Notes.save()
    passthrough
  end

  # -----------------------------------------------------------------------------
  # MOTD
  # -----------------------------------------------------------------------------
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

  # -----------------------------------------------------------------------------
  # Output
  # -----------------------------------------------------------------------------
  defp log_response(%{steps: []} = state) do
    UI.debug("Response complete")
    state
  end

  defp log_response(%{last_response: thought} = state) do
    # "Reasoning" models often leave the <think> tags in the response.
    thought =
      thought
      |> String.replace(~r/<think>(.*)<\/think>/, "\\1")
      |> Util.truncate(25)
      |> UI.italicize()

    UI.debug("Considering", thought)
    state
  end

  defp log_usage(%{usage: usage} = state) do
    UI.log_usage(@model, usage)
    state
  end

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

  # ---------------------------------------------------------------------------
  # Delayed Interrupt Display
  # ---------------------------------------------------------------------------
  # Public wrapper for testing delayed interrupt display
  @spec startinterrupt_listener(t) :: t
  defp startinterrupt_listener(%{conversation_pid: convo} = state) do
    # Only start in interactive TTY sessions and only for Coordinator
    cond do
      Map.get(state, :interrupt_listener) != nil ->
        state

      UI.quiet?() ->
        state

      UI.is_tty?() ->
        task =
          Task.start(fn ->
            listener_loop(convo, true)
          end)
          |> elem(1)

        Map.put(state, :interrupt_listener, task)

      true ->
        state
    end
  end

  defp listener_loop(convo_pid, show_msg? \\ false) do
    if show_msg? do
      UI.info(
        "Use enter (or ctrl-j) to interrupt and send feedback to the agent.\nNote: interrupts are applied between steps (before the next model call or after a tool batch). They do not preempt in-flight tool calls."
      )
    end

    case IO.getn(:stdio, "", 1) do
      "\n" ->
        # If interrupts are blocked (e.g., during finalization), refuse immediately
        if Services.Conversation.Interrupts.blocked?(convo_pid) do
          conv_id = Services.Conversation.get_id(convo_pid)

          UI.warn(
            "Finalizing in progress: interrupts cannot be delivered right now.",
            "Ongoing tool operations may complete. Use `-f #{conv_id}` to follow this conversation and queue a new question."
          )

          listener_loop(convo_pid)
        else
          "What would you like to say? (empty to ignore)"
          |> UI.prompt(optional: true)
          |> case do
            {:error, _} ->
              :ok

            nil ->
              :ok

            msg when is_binary(msg) ->
              msg
              |> String.trim()
              |> case do
                "" ->
                  :ok

                msg ->
                  Services.Conversation.interrupt(convo_pid, msg)
                  # defer UI echo until after completion cycle
                  :ok
              end

            _ ->
              :ok
          end

          listener_loop(convo_pid, true)
        end

      _other ->
        # Ignore any other input
        listener_loop(convo_pid)
    end
  end

  # -----------------------------------------------------------------------------
  # Tool box
  # -----------------------------------------------------------------------------
  @spec get_tools(t) :: AI.Tools.toolbox()
  defp get_tools(%{edit?: true}) do
    AI.Tools.basic_tools()
    |> AI.Tools.with_task_tools()
    |> AI.Tools.with_rw_tools()
    |> AI.Tools.with_coding_tools()
    |> AI.Tools.with_web_tools()
  end

  defp get_tools(_) do
    AI.Tools.basic_tools()
    |> AI.Tools.with_task_tools()
    |> AI.Tools.with_web_tools()
  end

  # -----------------------------------------------------------------------------
  # Tasking Guidance
  # -----------------------------------------------------------------------------
  @spec research_tasklist_msg(t) :: t
  defp research_tasklist_msg(%{conversation_pid: conversation_pid} = state) do
    """
    Use your task list to manage ALL research lines of inquiry.

    - For every new line of inquiry, create a task (short label + detailed description).
      Include rationale, next actions, and expected signals (files/components/behaviors).
    - When you conclude or drop a line, resolve its task with a clear outcome.
    - Before moving to the next step, call `tasks_show_list` to review open tasks and add follow-ups if needed.
    - Do NOT rely on ad-hoc text; track lines of inquiry explicitly in the task list.
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec coding_milestone_msg(t) :: t
  defp coding_milestone_msg(%{conversation_pid: conversation_pid} = state) do
    """
    - Treat the coder tool's iterative goals as sub-steps toward milestones.
    - At each coding iteration:
      - Review your task list for milestone tasks; update/add as needed.
      - Ensure current work aligns with milestones; if not, record follow-ups and adjust plan.
    - Use `tasks_show_list` to render current status before each iteration.
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec penultimate_tasks_check_msg(t, list) :: t
  defp penultimate_tasks_check_msg(%{conversation_pid: conversation_pid} = state, list_ids) do
    md_list =
      list_ids
      |> Enum.map(&" - ID: `#{&1}`")
      |> Enum.join("\n")

    """
    # Task lists check-in
    Task lists are persisted with the conversation.

    It is OK to leave tasks open across multiple sessions when they represent real follow-up work.
    - Use `tasks_show_list` and read it carefully.
    - If a task is done, resolve it.
    - If a task should not persist (stale, superseded, or no longer relevant), resolve it with a short note explaining why.
    - If a task is vague, rewrite it into a concrete follow-up (label + detailed description + rationale).

    The following task lists still have incomplete tasks:
    #{md_list}
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec task_list_msg(t) :: t
  defp task_list_msg(%{conversation_pid: conversation_pid} = state) do
    tasks =
      Services.Task.list_ids()
      |> Enum.map(fn list_id ->
        tasks = Services.Task.as_string(list_id)

        """
        ## Task list ID: `#{list_id}`
        Use this ID when invoking task management tools for this list.
        #{tasks}
        """
      end)
      |> Enum.join("\n\n")

    """
    # Tasks
    The `tasks_show_list` tool displays these tasks in more detail, including descriptions and statuses.
    #{tasks}
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  # -----------------------------------------------------------------------------
  # Testing response
  # -----------------------------------------------------------------------------
  @test_prompt """
  Perform the requested test exactly as instructed by the user.

  If this were not a test, the following information would be provided.
  Include it in your response to the user if it is relevant to the test:
  You are assisting the user by researching their question about the project, "$$PROJECT$$."
  $$GIT_INFO$$

  If the user explicitly requests a (*literal*) `mic check`:
    - Respond (only) with a haiku that is meaningful to you
    - Remember a proper kigo

  If the user is requesting a (*literal*) `smoke test`, test **ALL** of your available tools in turn
    - **TEST EVERY SINGLE TOOL YOU HAVE ONCE**
    - **DO NOT SKIP ANY TOOL**
    - **COMBINE AS MANY TOOL CALLS AS POSSIBLE INTO THE SAME RESPONSE** to take advantage of concurrent tool execution
      - Pay attention to logical dependencies between tools to get real values for arguments
      - For example, you must call `file_list_tool` before other file tool calls to ensure you have valid file names to use as arguments
    - Consider the logical dependencies between tools in order to get real values for arguments
      - For example:
        - The file_contents_tool requires a file name, which can be obtained from the file_list_tool
        - Git diff commands require branch names, which can be obtained using `shell_tool` with `git branch`
    - The user will verify that you called EVERY tool using the debug logs
    - Start with the file_list_tool so you have real file names for your other tests
    - Respond with a section for each tool:
      - In the header, prefix the tool name with a `✓` or `✗` to indicate success or failure
      - Note which arguments you used for the tool
      - Report success, errors, and anomalies encountered while executing the tool

  Otherwise, perform the actions requested by the user and report the results.
  Keep in mind that the user cannot see the rest of the conversation - only your final response.
  Report any anomalies or errors encountered during the process and provide a summary of the outcomes.
  """

  @spec is_testing?(t) :: boolean
  defp is_testing?(%{question: question}) do
    question
    |> String.downcase()
    |> String.starts_with?("testing:")
  end

  @spec get_test_response(t) :: {:error, :testing}
  defp get_test_response(%{project: project} = state) do
    # Enable all tools for testing.
    tools =
      AI.Tools.basic_tools()
      |> AI.Tools.with_task_tools()
      |> AI.Tools.with_coding_tools()
      |> AI.Tools.with_rw_tools()
      |> AI.Tools.with_web_tools()

    AI.Agent.get_completion(state.agent,
      log_msgs: true,
      log_tool_calls: true,
      model: AI.Model.fast(),
      toolbox: tools,
      messages: [
        @test_prompt
        |> String.replace("$$PROJECT$$", project)
        |> String.replace("$$GIT_INFO$$", git_info())
        |> AI.Util.system_msg(),
        AI.Util.user_msg(state.question)
      ]
    )
    |> case do
      {:ok, %{response: msg} = response} ->
        UI.say(msg)

        response
        |> AI.Agent.tools_used()
        |> Enum.each(fn {tool, count} ->
          UI.report_step(tool, "called #{count} time(s)")
        end)

        log_usage(response)

      {:error, reason} ->
        UI.error(inspect(reason))
    end

    {:error, :testing}
  end
end
