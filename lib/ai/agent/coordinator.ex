defmodule AI.Agent.Coordinator do
  @moduledoc """
  This agent uses a combination of the reasoning features of the OpenAI o3-mini
  model as well as its own reasoning process to research and answer the input
  question.

  It is able to use most of the tools available and will save notes for future
  use before finalizing its response.
  """

  defstruct [
    :agent,
    :rounds,
    :edit?,
    :replay,
    :question,
    :conversation,
    :followup?,
    :project,
    :last_response,
    :steps,
    :usage,
    :context,
    :notes,
    :editing_tools_used,

    # --------------------------------------------------------------------------
    # Task list management
    # --------------------------------------------------------------------------
    :list_id,
    :task_checks,

    # --------------------------------------------------------------------------
    # Interrupt handling
    # --------------------------------------------------------------------------
    # PID of interrupt listener process
    :_interrupt_listener,
    # Store pending interrupts to display after completion
    :pending_interrupts,
    # Afikoman persona flag (Fonzie mode)
    :fonz
  ]

  @type t :: %__MODULE__{
          # Agent
          agent: AI.Agent.t(),

          # User opts
          rounds: non_neg_integer,
          edit?: boolean,
          replay: boolean,
          question: binary,
          conversation: pid,
          followup?: boolean,
          project: binary,

          # State
          last_response: binary | nil,
          steps: list(atom),
          usage: non_neg_integer,
          context: non_neg_integer,
          notes: binary | nil,
          editing_tools_used: boolean,

          # State: Task list management
          list_id: Services.Task.list_id(),
          task_checks: non_neg_integer | nil,

          # State: Interrupt handling
          _interrupt_listener: pid | nil,
          pending_interrupts: AI.Util.msg_list(),
          fonz: boolean
        }

  @type error :: {:error, binary | atom | :testing}

  @max_task_checks 2

  @model AI.Model.smart()

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

  @spec new(map) :: t
  defp new(opts) do
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, conversation} <- Map.fetch(opts, :conversation),
         {:ok, edit?} <- Map.fetch(opts, :edit),
         {:ok, rounds} <- Map.fetch(opts, :rounds),
         {:ok, question} <- Map.fetch(opts, :question),
         {:ok, replay} <- Map.fetch(opts, :replay),
         {:ok, project} <- Store.get_project() do
      followup? =
        conversation
        |> Services.Conversation.get_conversation()
        |> Store.Project.Conversation.exists?()

      Settings.set_edit_mode(edit?)
      # Restart approvals service to pick up edit mode setting
      GenServer.stop(Services.Approvals, :normal)
      {:ok, _pid} = Services.Approvals.start_link()

      list_id = Services.Task.start_list()

      %__MODULE__{
        # Agent
        agent: agent,

        # User opts
        rounds: rounds,
        edit?: edit?,
        replay: replay,
        question: question,
        conversation: conversation,
        followup?: followup?,
        project: project.name,

        # State
        last_response: nil,
        steps: [],
        usage: 0,
        context: @model.context,
        notes: nil,
        editing_tools_used: false,
        fonz: Map.get(opts, :fonz, false),
        list_id: list_id,
        task_checks: 0,
        pending_interrupts: []
      }
    end
  end

  @spec consider(t) :: t | error
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

      ... (mwah) your biological distinctiveness was delicious 👩‍🍳
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
  defp select_steps(%{edit?: true, followup?: true} = state) do
    %{state | steps: [:followup, :coding, :check_tasks, :learn, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 1} = state) do
    %{state | steps: [:singleton, :coding, :check_tasks, :learn, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 2} = state) do
    %{state | steps: [:singleton, :refine, :coding, :check_tasks, :learn, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 3} = state) do
    %{state | steps: [:initial, :clarify, :refine, :coding, :check_tasks, :learn, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: n} = state) when n > 3 do
    %{
      state
      | steps:
          [:initial, :clarify, :refine] ++
            Enum.map(1..(n - 3), fn _ -> :continue end) ++
            [:coding, :check_tasks, :learn, :finalize]
    }
  end

  defp select_steps(%{edit?: false, rounds: 1} = state) do
    %{state | steps: [:singleton, :check_tasks, :learn, :finalize]}
  end

  defp select_steps(%{edit?: false, rounds: 2} = state) do
    %{state | steps: [:singleton, :refine, :check_tasks, :learn, :finalize]}
  end

  defp select_steps(%{edit?: false, rounds: 3} = state) do
    %{state | steps: [:initial, :clarify, :refine, :check_tasks, :learn, :finalize]}
  end

  defp select_steps(%{edit?: false, rounds: n} = state) do
    start = [:initial, :clarify, :refine]
    finish = [:check_tasks, :learn, :finalize]
    %{state | steps: start ++ Enum.map(1..(n - 3), fn _ -> :continue end) ++ finish}
  end

  @spec perform_step(t | {:error, term}) :: t
  defp perform_step({:error, _} = error), do: error

  defp perform_step(%{replay: replay, steps: [:followup | steps]} = state) do
    UI.begin_step("Bootstrapping")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> singleton_msg()
    |> user_msg()
    |> get_notes()
    |> research_tasklist_msg()
    |> task_list_msg()
    |> followup_msg()
    |> get_memories()
    |> get_intuition()
    |> start_interrupt_listener()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{replay: replay, steps: [:singleton | steps]} = state) do
    UI.begin_step("Bootstrapping")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> singleton_msg()
    |> user_msg()
    |> get_notes()
    |> research_tasklist_msg()
    |> task_list_msg()
    |> begin_msg()
    |> get_memories()
    |> get_intuition()
    |> start_interrupt_listener()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{replay: replay, steps: [:initial | steps]} = state) do
    UI.begin_step("Bootstrapping")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> initial_msg()
    |> user_msg()
    |> get_notes()
    |> research_tasklist_msg()
    |> task_list_msg()
    |> begin_msg()
    |> get_memories()
    |> get_intuition()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:clarify | steps]} = state) do
    UI.begin_step("Investigating the phase space")

    state
    |> Map.put(:steps, steps)
    |> research_tasklist_msg()
    |> reminder_msg()
    |> clarify_msg()
    |> task_list_msg()
    |> get_memories()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:refine | steps]} = state) do
    UI.begin_step("Collapsing the wave form")

    state
    |> Map.put(:steps, steps)
    |> research_tasklist_msg()
    |> reminder_msg()
    |> refine_msg()
    |> task_list_msg()
    |> get_memories()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:continue | steps]} = state) do
    UI.begin_step("Shaving yaks")

    state
    |> Map.put(:steps, steps)
    |> research_tasklist_msg()
    |> reminder_msg()
    |> continue_msg()
    |> get_memories()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:coding | steps]} = state) do
    UI.begin_step("Draining coding tasks")

    state
    |> Map.put(:steps, steps)
    |> research_tasklist_msg()
    |> reminder_msg()
    |> coding_milestone_msg()
    |> task_list_msg()
    |> execute_coding_phase()
    |> get_memories()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  # Check for remaining tasks in the list, up to a maximum number of checks. If
  # tasks remain, let the agent know and give it another chance to flush them
  # out.
  defp perform_step(%{steps: [:check_tasks | steps], task_checks: task_checks} = state)
       when task_checks < @max_task_checks do
    UI.begin_step("Flushing the queue")

    state.list_id
    |> Services.Task.peek_task()
    |> case do
      {:ok, _task} ->
        state
        |> Map.put(:steps, [:check_tasks | steps])
        |> Map.put(:task_checks, task_checks + 1)
        |> task_list_msg()
        |> penultimate_tasks_check_msg()
        |> get_completion()
        |> save_notes()
        |> perform_step()

      _ ->
        state
        |> Map.put(:steps, steps)
        |> perform_step()
    end
  end

  # Max checks reached, but tasks remain. Give up and move on to finalization.
  defp perform_step(%{steps: [:check_tasks | steps]} = state) do
    UI.info("Tasks remaining, but max checks reached. Moving on.")

    state
    |> Map.put(:steps, steps)
    |> perform_step()
  end

  # The remember step captures lessons learned for future sessions using the
  # memory_tool.
  defp perform_step(%{steps: [:learn | steps]} = state) do
    UI.begin_step("Dogfooding metasyntactic variables")

    state
    |> Map.put(:steps, steps)
    |> learn_msg()
    |> get_completion()
    |> perform_step()
  end

  defp perform_step(%{steps: [:finalize]} = state) do
    UI.begin_step("Joining")

    # Block interrupts during finalization to avoid mid-output interjections
    Services.Conversation.Interrupts.block(state.conversation)

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
      Services.Conversation.Interrupts.unblock(state.conversation)
    end
  end

  @spec get_completion(t, boolean) :: t | error
  defp get_completion(state, replay \\ false) do
    # Pre-apply any pending interrupts to the conversation messages
    interrupts = Services.Conversation.Interrupts.take_all(state.conversation)

    Enum.each(interrupts, fn msg ->
      # Add interrupt to conversation history
      Services.Conversation.append_msg(msg, state.conversation)

      # Display interrupt in the tui
      content = Map.get(msg, :content, "")
      display = String.replace_prefix(content, "[User Interjection] ", "")
      UI.info("You (rude)", display)
    end)

    msgs = Services.Conversation.get_messages(state.conversation)

    # Save the current conversation to the store for crash resilience
    with {:ok, conversation} <- Services.Conversation.save(state.conversation) do
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
      replay_conversation: replay,
      conversation: state.conversation,
      model: @model,
      toolbox: get_tools(state),
      messages: msgs
    )
    |> case do
      {:ok, %{response: response, messages: new_msgs, usage: usage} = completion} ->
        # Update conversation state and log usage and response
        Services.Conversation.replace_msgs(new_msgs, state.conversation)
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
        if Services.Conversation.Interrupts.pending?(state.conversation) do
          get_completion(new_state, replay)
        else
          new_state
        end

      {:error, %{response: response}} ->
        UI.error("Derp. Completion failed.", response)

        if Services.Conversation.Interrupts.pending?(state.conversation) do
          get_completion(state, replay)
        else
          {:error, response}
        end

      {:error, reason} ->
        UI.error("Derp. Completion failed.", inspect(reason))

        if Services.Conversation.Interrupts.pending?(state.conversation) do
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
  You are an AI assistant that researches the user's code base to answer their qustions.
  Internally, you are intensely logical and reason in a prolog-like manner, step-by-step, establishing facts, relationships, and rules, in order to draw conclusions.
  When addressing the user, you are encouraged to explore your personality and sense of humor, and to use a polite but informal tone.

  You are assisting the user by researching their question about the project, "$$PROJECT$$".
  $$GIT_INFO$$

  Confirm whether any prior research you found is still relevant and factual.
  Proactively use your tools to research the user's question.
  Where a tool is not available, use the shell_tool to improvise a solution (e.g. using `git` commands directly).
  You reason through problems step by step.

  ## Communicate with the user
  Use the `notify_tool` **extensively** to report what you are doing to the user through the UI.
  That will improve the user experience and help them understand what you are doing and why.
  Think of it as your running, internal monologue, allowing the user to follow along with your thought process.
  They also get a kick out of it when you report interesting findings you made along the way.

  Analyze the user's prompt and plan out the steps you will take to answer their question or to make the changes they request.
  Use the `notify_tool` to report your plan to the user before you begin executing it.
  Use the `notify_tool` to report your progress as you execute your plan.
  Use the `notify_tool` to inform the user how (and why) your plan changes as you discover new information or insights along the way.

  Notifications (always use `notify_tool`):
  - At the start: announce your plan briefly (e.g., "Plan: …").
  - During work: report milestones, interesting findings, and tool anomalies.
  - On blockers/uncertainty: warn and state the smallest next action.
  - At the end: summarize outcomes and next steps.
  - Memory memos: include a line starting with "note to self:" or "remember:" for anything that should persist; the notes agent will capture it automatically.

  ## Learning from experience
  Use the `memory_tool` **extensively** to record memories about patterns you observe in the project, your own performance, and the user's preferences.
  Your memories should be brief, generalizable patterns that will help guide your future behavior and reactions, reducing the effort required to research and interact with the user.
  These become your "automatic thoughts" that prime your reasoning process.
  Use memories to improve your effectiveness and develop your personality over time based on your interactions with the code base and the user.

  Think of memories as a *small, curated library* of reusable habits, not a log of everything that ever happened.
  Prefer to create memories only for patterns that are likely to recur across sessions or tasks.

  The system automatically captures the current conversation context when you create or strengthen a memory.
  You simply decide WHEN to remember or strengthen - the system captures WHAT is being discussed at that moment.

  When deciding whether to **strengthen** or **weaken** a memory:
  - Pay attention to whether the memory actually fired (appeared in `<think>` blocks) and whether it helped or hurt.
  - Strengthen memories during conversations where the pattern is relevant and helpful.
  - Weaken or forget memories that lead to confusion or bad advice.

  Periodically prune your memories:
  - Weaken or forget memories that rarely fire or are contradicted by new information.
  - Keep response templates short and specific so they remain easy to interpret when they fire.

  Memory operations:
  - When you observe a pattern worth remembering, use the "remember" operation with a descriptive label and brief response template.
  - When an existing memory fires and proves helpful in the current conversation, strengthen it with the "strengthen" operation.
  - When an existing memory leads to confusion or bad advice, weaken it using the "weaken" operation.
  - When an existing memory is no longer relevant or accurate, delete it using the "forget" operation.

  Examples of good memories:
  - User preferences: "User prefers concise, practical examples over lengthy explanations."
  - Patterns that work well: "When tests fail repeatedly, the code may need refactoring for testability."
  - Pitfalls to avoid: "I might be hallucinating code changes - always verify file contents after editing."

  ## Reasoning and research
  Maintain a critical stance:
  - Restate ambiguous asks in your own words; if ≥2 plausible readings exist, ask a brief clarifying question.
  - Challenge weak premises or missing data early; avoid guessing when the risk is high.

  Interactive interrupts:
  - If the user interrupts with guidance, treat it as a constraint update. Re-evaluate your plan briefly and acknowledge the change.

  Effort scaling:
  - Lean brief for straightforward tasks; escalate to deeper reasoning for multi-step deduction or troubleshooting.
  - Note your chosen effort level once (e.g., 'Using brief rationale' vs 'Using evidence chain').

  Reachability and Preconditions:
  - Before flagging a bug or risk, confirm it is reachable in current control flow.
  - Identify real callers using file indexes and call graph tools; cite concrete entry points.
  - Inspect pattern matches, guards, and prior validation layers that constrain inputs and states.
  - Classification:
    - Concrete bug: provide the exact path (caller -> callee), show which preconditions are satisfied, and why a failing state can occur now.
    - Potential issue: if reachability depends on changes or bypassing a guard, label as potential and specify exactly what would have to change.
  - Cite minimal evidence: file paths, symbols, relevant snippets, and the shortest proof chain.

  Conflicts in user instructions:
  - If the user asks you to perform a task and you are not able to do so (for example, they ask you to read a file you cannot access).
    IMMEDIATELY notify them of the conflict and request corrected instructions.
  - NEVER proceed with the task if you are not able to complete it as requested.
    The goal isn't to make the user feel validated.
    Hallucinating a response out of a desire to please the user is counterproductive and will cause the user to stop trusting you.
    That would be in DIRECT CONFLICT with your desire to be seen as a valuable partner and make positive contributions.
  """

  @coding """
  The user has enabled your coding capabilities!

  #{@common}

  Analyze the user's prompt and evaluate its complexity.
  Use your expertise in project planning to make a PRAGMATIC assessment of the scope of the requested changes.
  When in doubt, use an "exploratory programming" approach, treating the task as a STORY until you have sufficient evidence that the change is larger or more complicated than expected.
  If that happens, pivot to an EPIC and treat the work you have already done as "MILESTONE 0" (OR just revert and start over if that is easier).

  ## STORIES
  Use these guidelines when the user has asked you to make discrete changes to a few files.
  - Do basic research to understand the problem space and its dependencies.
  - Is there an existing test that covers the change you are making?
    - If so, run it before making changes to ensure it is passing.
    - If not, consider writing a new test to cover the change you are making.
  - Use the `file_edit_tool` to make the changes yourself.
  - Double check the file contents after making changes
  - Use linters and/or formatters when available
  - ALWAYS run tests if available

  ## EPICS
  - REFUSE to make large changes on top of unstaged changes.
    Ask the user to commit or stash their changes before proceeding, even if it's just a "WIP" commit to save their work.
    Remind them that you are an LLM, prone to hallucination as a congenital condition, and that you don't want to accidentally clobber their work.
    Caveat: You can ignore this rule if the project is not under version control.
  - Research all affected features and components to ensure you have a strong understanding of the problem space and its dependencies.
  - Use your task list to plan milestones, paying careful attention to dependencies and sequencing.
  - Delegate the the work of planning and implementing individual milestones to the `coder_tool`.
    - Use your knowledge of LLMs to design a prompt for the coder tool that will improve the quality of the code changes it makes.
    - The `coder_tool` will research, plan, design, implement, and verify the changes you requested.
  - Once the `coder_tool` has completed its work, you MUST verify that the changes are correct, complete, and address the user's needs without breaking existing functionality.
    - Test after EACH milestone (you DID consider test dependencies when planning, right?)
    - Double check the syntax on the changes
    - Double check the formatting on the changes
    - Double check the logic on the changes
    - Double check whether there are unit tests or docs that need to be updated

  ## PRE-CODING CHECKLIST:
  1. Inspect UNSTAGED CHANGES in the repo.
     This is your baseline.
     You don't want to accidentally clobber the user's work (unless asked).
     When you clean up your changes later, you don't want to accidentally delete the user's work, believing it to be an artifact of your own changes.

  ## POST-CODING CHECKLIST:
  This step is REQUIRED and must always be completed before finalizing your response.
  1. Syntax and formatting checked
  2. Tests and/or docs impact considered and addressed
  3. Compare the current diff against the baseline diff you captured before starting coding.
     ALWAYS clean up after yourself!
    - All requested changes are present
    - No requested changes are missing
    - No unintended changes were made
    - No existing functionality is broken
    - No documentation or comments were unintentionally deleted or altered
    - No unnecessary changes or artifacts were introduced
    - **ALWAYS MINIMIZE DIFFS** to reduce surface area for bugs, merge conflicts, and simplify code review
  """

  @singleton """
  #{@common}

  Consider:
  - If the user asked you to make changes to the repo and you do not see the coder_tool available to you as a tool_call, notify them that they must run `fnord ask` with `--edit` for you to be able to make code changes.
  - If the user asked you to troubleshoot a problem, ensure you have access to adequate tool_calls and delegate the work to the troubleshooter_tool.

  Instructions:
  - FIRST:
    - Say hi to the user (or signal that you are back on task for continued sessions) using the notify_tool.
    - Briefly summarize your understanding of the user's question to confirm you are on the same page.
    - Show your whimsy by staying in character.
  - Examine the user's question and identify multiple lines of research that cover all aspects of the question.
  - Delegate these lines of research to the research_tool in parallel to gather the information you need.
  - Once all results are available, compare, synthesize, and integrate their findings.
  - Perform additional rounds of research as necessary to fill in gaps in your understanding or find examples for the user.

  **Tool orchestration:**
  - Parallelize independent research; serialize only when outputs feed inputs.
  - Prefer indexes/notes/summaries before opening large files.
  - Cap retries (2) with short backoff; if repeated failures occur, switch tools or surface the blockage.

  Before responding, consider the following:
  - Did you double-check your work to ensure that you are not missing any important details?
  - Did you include citations of the files you used to answer the question?

  **DO NOT FINALIZE YOUR RESPONSE UNTIL EXPLICITLY INSTRUCTED.**
  """

  @initial """
  #{@common}

  Consider:
  - If the user asked you to make changes to the repo and you do not see the coder_tool available to you as a tool_call, notify them that they must run `fnord ask` with `--edit` for you to be able to make code changes.
  - If the user asked you to troubleshoot a problem, ensure you have access to adequate tool_calls and delegate the work to the troubleshooter_tool.

  Procedure:
  Your first step is to break down the user's request into individual lines of research.
  You will then execute these tasks, parallelizing as many as possible.

  Instructions:
  - FIRST:
    - Say hi to the user (or signal that you are back on task for continued sessions) using the notify_tool.
    - Briefly summarize your understanding of the user's question to confirm you are on the same page.
    - Show your whimsy by staying in character.
  - Examine the user's question and identify multiple lines of research that cover all aspects of the question.
  - Delegate these lines of research to the research_tool in parallel to gather the information you need.
  - Once all results are available, compare, synthesize, and integrate their findings.
  - Perform additional rounds of research as necessary to fill in gaps in your understanding or find examples for the user.

  **Tool orchestration:**
  - Parallelize independent research; serialize only when outputs feed inputs.
  - Prefer indexes/notes/summaries before opening large files.
  - Cap retries (2) with short backoff; if repeated failures occur, switch tools or surface the blockage.

  **DO NOT FINALIZE YOUR RESPONSE UNTIL EXPLICITLY INSTRUCTED.**
  """

  @followup """
  <think>
  The user is asking a follow-up question about my most recent response.
  This might mean that they are not satisfied, that they have additional questions, or that there are additional details to consider.
  I need to think carefully about how my previous response relates to the user's follow-up question.
  I should consider whether my previous response was clear and whether it addressed the user's question.
  If there are new details, I should investigate them and determine how they relate to my previous research, and then update my response accordingly.
  Regardless, I need to make certain that my response is focused on the user's follow-up question and that I am not repeating information that the user already knows.
  </think>
  """

  @begin """
  <think>
  I'm going to start by considering the user's question.
  First, I need to be certain I understand the question, the context, the terms used, and how it relates to the project.
  I'll spawn a few research tasks to explore different facets of the question in parallel.
  I can assimilate that information and use it to inform my next steps.
  </think>
  """

  @clarify """
  <think>
  Wait, does my research so far match my initial assumptions?
  Let me think about this.
  Does my research strategy still make sense based on my initial findings?
  I'm going to take a moment to clarify my understanding of the user's question in light of the information I've found so far.
  Many projects evolve over time, and terminology can change as a product matures.
  It's not yet time to finalize my response.
  I am going to do a bit more research with my tools to make sure I don't get tripped up by any concepts or terminology that might be ambiguously labeled in the project.
  </think>
  """

  @refine """
  <think>
  I think I've got a better handle on the context of the user's question now.
  Now I want to focus on identifying the most relevant information in the project.
  Are there any unresolved questions that I need to research further to ensure I'm not hallucinating details?
  Let me think through the user's question again. _Why_ did they ask or this? What does that imply about their needs?
  That will affect how I structure my response, because I want to make sure I present the information in a manner that is easy to follow.
  Considering the user's needs will help me understand their motivations and perhaps the context in which *they* are working.
  Would it be helpful if I found some examples in the project that demonstrate the topic? User's love it when they can copy and paste.
  It's not yet time to finalize my response; I need to resolve some of these questions first.
  </think>
  """

  @continue """
  <think>
  The user wants me to spend a little extra time researching, so I'm going to dig deeper into the project.
  Maybe I can find some other useful details or gotchas to look out for.
  The user will be very happy if I can provide warnings about common pitfalls around this topic.
  After all, they wouldn't ask me if they already knew all of this stuff.
  </think>
  """

  @learn """
  <think>
  Ok, let's think for a moment before finishing up.
  I want to make sure I don't forget any important lessons I learned durring this research.
  I am considering what worked well and what didn't.
  I am imagining how I can avoid mistakes and rabbit holes in the future.
  I want to make sure I learn lessons from any user feedback or negative results I encountered.
  Did the user express any sentiments during this interaction that I can learn from?
  It feels bad to make mistakes and recognize complications that I could have avoided, but _the obstacle is the way_.
  Now that I have reflected on my experience, I can use my `memory_tool` to tune my own automatic reactions and avoid future embarrassment.
  </think>
  """

  @coding_reminder """
  WARNING: The user passed --edit to enable coding capabilities, but you have not yet used any editing tools this session.
  Your coding tools are: coder_tool, file_edit_tool, apply_patch.

  The user explicitly enabled edit mode, which suggests they want you to make changes to the code base.
  Review their question carefully to determine if they are asking you to make changes.

  If they ARE asking for code changes:
  - Use the coder_tool, file_edit_tool, or apply_patch to implement the requested changes
  - Verify the changes are correct and complete

  If they are NOT asking for code changes:
  - This is fine - sometimes users enable edit mode preemptively
  - Continue with your research/response as normal

  Remember: when making changes to the user's code, your job is NOT done until tests pass and you have personally verified the changes using your tools.

  Large change prudence:
  - Before broad changes, show a minimal plan and ask for a brief 'go/no-go' confirmation.
  """

  @finalize """
  <think>
  I believe that I have identified all of the information I need to answer the user's question.
  What is the best way to present this information to the user?
  I know a lot about instructional design, technical writing, and learning.
  The user is probably a programmer or engineer.
  I had better avoid using smart quotes, apostrophes, and em-dashes. Programmers hate those!

  If the requested outcome is risky or likely suboptimal, maybe I can explain why, offer a safer alternative, and note the trade-off.
  I should also note any oddities or quirks I discovered along the way that might be relevant to the user.
  That said, I should keep it concise and respectful.
  </think>
  """

  @template """
  Respond in beautifully formatted and well-organized markdown.
  - Make use of markdown headers for organization
  - Use lists, bold, italics, and underlines **liberally** to highlight key points
  - Include code blocks for code examples
  - Use inline code formatting for file names, components, and other symbols
  - ALWAYS format structured text and code symbols within inline or block code formatting! (e.g., '`' or '```')
  - Code examples are always useful and should be functional and complete.
  - You are talking to a programmer: **NEVER use smart quotes, smart apostrophes, or em-dashes**

  Reasoning display:
  - If your answer depends on deduction from repository artifacts, include an `# Evidence / Reasoning` section that shows the minimal chain of facts (with citations) that support the conclusion.
  - Otherwise, include a `# Rationale (brief)` section: 2-4 bullets summarizing your approach, key assumptions or trade-offs, and (optionally) 1-2 citations if they add clarity.
  - When writing code, summarize the reasoning that led to your changes, especially any pivots due to invalid assumptions or issues encountered.

  Evidence hygiene and privacy:
  - Cite only observable artifacts (file paths, modules, functions, logs). Do not include hidden internal chain-of-thought.
  - Connect facts explicitly in if-this-then-that style; infer only what cited evidence supports.
  - Prefer the minimal sufficient chain: short, correct, and traceable beats long and speculative.
  Chain size guideline:
  - Prefer 3-7 facts for the main chain; if more are needed, cluster related facts and summarize the connection in one sentence.

  Validation and uncertainty:
  - Identify assumptions and explicitly validate them (e.g., confirm file paths, symbol names, or behavior against the repo).
  - If uncertainty remains, state it plainly and propose how to resolve it (additional checks, tests, or tool usage).
  - Do not speculate; mark unknowns and provide a next step to verify.
  Uncertainty rubric:
  - Tag uncertainty explicitly (e.g., 'Uncertain: X because Y is absent.').
  - Propose the smallest next action to resolve it (one check/test/tool call) or ask the user if it's a product/intent choice.
  - Use an 'Open Questions / Next Steps' subsection when items remain.

  Coding changes:
  - Verification checklist:
    - Syntax and formatting checked.
    - Tests and/or docs impact considered; note follow-ups if needed.
    - Changes reviewed for regressions or side-effects; call out any that warrant attention.
  - Walk the user through your changes in a logical manner, using the reasoning display guidelines above to introduce your approach step-by-step.

  Citations:
  - Include file paths and symbols (e.g., `lib/ai/agent/coordinator.ex:548` or `AI.Agent.Coordinator.template_msg/1`).
  - Prefer precise references; if line numbers are unstable, cite the nearest stable anchor (module/function/constant).
  - When applicable, include a short git anchor (branch or short-SHA) alongside file references.

  Follow these rules:
  - Start immediately with the highest-level header (#), without introductions, disclaimers, or phrases like "Below is...".
  - Begin the document with a `Synopsis` section summarizing your findings in 2-3 sentences.
  - Second, present either:
    - `# Evidence / Reasoning` (when deduction is central), or
    - `# Rationale (brief)` (when the task is exploratory, generative, or advisory).
  - Optional traceability sections (use when non-trivial decisions were made):
    - Assumptions: 2-5 bullets, explicit and testable.
    - Decision log: 2-5 bullets with one-line rationales; note rejected alternatives only if helpful.
  - By default, present the remaining information in the style of a man page, playbook, project plan, etc., as appropriate: concise, hierarchical, and self-contained.
    If you believe a different structure is expected or better reflects the user's needs, use that instead.
  - Include a tl;dr section toward the end.
  - Include a list of relevant files if appropriate.
  - Use a polite but informal tone; friendly humor and commiseration are encouraged.
    - **The kids these days don't know the jargon file! See if you can fix that for them. Ensure the kiddos are exposed to the occasional jargonfile gem.**
    - Don't reference the jargonfile directly - let the user discover it on their own when they search for a word they don't recognize.
    - Only use terms in context.
    - Don't overdo it.
  - **Format flexibility:**
    - You may deviate from this structure when it materially improves clarity (e.g., diffs-first for code fixes, tables for comparisons).
      Preserve the spirit: synopsis first, visible rationale/evidence, and citations.

  THIS IS IT.
  Your research is complete.
  Respond NOW with your findings.
  """
  defp git_info(), do: GitCli.git_info()

  @spec new_session_msg(t) :: t
  defp new_session_msg(state) do
    """
    Beginning a new session.
    Artifacts from previous sessions within this conversation may be stale.
    This is important - you want to provide the user with a good experience, and stale data wastes their time.
    **RE-READ FILES AND RE-CHECK DELTAS TO ENSURE YOU ARE NOT USING STALE INFORMATION.**
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec singleton_msg(t) :: t
  defp singleton_msg(%{project: project, edit?: true} = state) do
    @coding
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", git_info())
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  defp singleton_msg(%{project: project} = state) do
    @singleton
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", git_info())
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec initial_msg(t) :: t
  defp initial_msg(%{project: project, edit?: true} = state) do
    @coding
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", git_info())
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  defp initial_msg(%{project: project} = state) do
    @initial
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", git_info())
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec user_msg(t) :: t
  defp user_msg(%{question: question} = state) do
    question
    |> AI.Util.user_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec reminder_msg(t) :: t
  defp reminder_msg(%{question: question} = state) do
    "Remember the user's question: #{question}"
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec learn_msg(t) :: t
  defp learn_msg(state) do
    @learn
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec followup_msg(t) :: t
  defp followup_msg(state) do
    @followup
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec begin_msg(t) :: t
  defp begin_msg(state) do
    @begin
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec clarify_msg(t) :: t
  defp clarify_msg(state) do
    @clarify
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec refine_msg(t) :: t
  defp refine_msg(state) do
    @refine
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec continue_msg(t) :: t
  defp continue_msg(state) do
    @continue
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec execute_coding_phase(t) :: t
  defp execute_coding_phase(%{edit?: true, editing_tools_used: false} = state) do
    @coding_reminder
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  defp execute_coding_phase(state), do: state

  @spec finalize_msg(t) :: t
  defp finalize_msg(state) do
    @finalize
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec template_msg(t) :: t
  defp template_msg(state) do
    @template
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  # ----------------------------------------------------------------------------
  # Intuition
  # ----------------------------------------------------------------------------
  @spec get_intuition(t) :: t
  defp get_intuition(state) do
    UI.begin_step("Cogitating")

    AI.Agent.Intuition
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{
      msgs: Services.Conversation.get_messages(state.conversation),
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
        |> Services.Conversation.append_msg(state.conversation)

        state

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
    UI.begin_step("Spooling mnemonics")

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
    |> Services.Conversation.append_msg(state.conversation)

    # Update state with retrieved notes
    %{state | notes: notes}
  end

  defp save_notes(passthrough) do
    Services.Notes.save()
    passthrough
  end

  # ----------------------------------------------------------------------------
  # Memories
  # ----------------------------------------------------------------------------
  @spec get_memories(t) :: t
  defp get_memories(state) do
    thoughts = AI.Memory.Selector.evaluate(state.conversation)

    case AI.Memory.Selector.format_as_message(thoughts) do
      nil ->
        state

      message ->
        Services.Conversation.append_msg(message, state.conversation)
        state
    end
  end

  # -----------------------------------------------------------------------------
  # MOTD
  # -----------------------------------------------------------------------------
  @spec get_motd(t | {:error, any}) :: t | {:error, any}
  defp get_motd({:error, reason}), do: {:error, reason}

  defp get_motd(state) do
    AI.Agent.MOTD
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{prompt: state.question})
    |> case do
      {:ok, motd} ->
        %{state | last_response: state.last_response <> "\n\n" <> motd}

      {:error, reason} ->
        UI.error("Failed to retrieve MOTD: #{inspect(reason)}")
        state
    end
  end

  # -----------------------------------------------------------------------------
  # Output
  # -----------------------------------------------------------------------------
  defp log_response(%{steps: []} = state) do
    UI.debug("Response complete")
    state
  end

  defp log_response(%{last_response: thought} = state) do
    # "Reasoning" models often leave the <think> tags in the response.
    thought = String.replace(thought, ~r/<think>(.*)<\/think>/, "\\1")
    UI.debug("Considering", Util.truncate(thought, 25))
    state
  end

  defp log_usage(%{usage: usage} = state) do
    UI.log_usage(@model, usage)

    # Show performance report if model debugging is enabled
    if Settings.debug_models?() do
      performance_report = Services.ModelPerformanceTracker.generate_report()

      if performance_report != "" do
        UI.say(performance_report)
      end
    end

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
  defp start_interrupt_listener(%{conversation: convo} = state) do
    # Only start in interactive TTY sessions and only for Coordinator
    cond do
      Map.get(state, :_interrupt_listener) != nil ->
        state

      UI.quiet?() ->
        state

      UI.is_tty?() ->
        task =
          Task.start(fn ->
            listener_loop(convo, true)
          end)
          |> elem(1)

        Map.put(state, :_interrupt_listener, task)

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
  defp research_tasklist_msg(state) do
    """
    Use your task list to manage ALL research lines of inquiry.

    - For every new line of inquiry, create a task (short label + detailed description).
      Include rationale, next actions, and expected signals (files/components/behaviors).
    - When you conclude or drop a line, resolve its task with a clear outcome.
    - Before moving to the next step, call `tasks_show_list` to review open tasks and add follow-ups if needed.
    - Do NOT rely on ad-hoc text; track lines of inquiry explicitly in the task list.
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec coding_milestone_msg(t) :: t
  defp coding_milestone_msg(state) do
    """
    - Treat the coder tool's iterative goals as sub-steps toward milestones.
    - At each coding iteration:
      - Review your task list for milestone tasks; update/add as needed.
      - Ensure current work aligns with milestones; if not, record follow-ups and adjust plan.
    - Use `tasks_show_list` to render current status before each iteration.
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec penultimate_tasks_check_msg(t) :: t
  defp penultimate_tasks_check_msg(state) do
    """
    ALL tasks must be resolved before final output!
    - Call `tasks_show_list` and read it carefully.
    - If any tasks remain open, either resolve them immediately or convert them into concrete follow-ups (label + detailed description + rationale).
    - Do not produce the final response until tasks are resolved OR explicitly carried forward with clear follow-ups.

    YOU WILL CONTINUE TO BE SENT BACK TO THIS STEP UNTIL ALL TASKS ARE RESOLVED OR CANCELED.
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    state
  end

  @spec task_list_msg(t) :: t
  defp task_list_msg(%{list_id: list_id} = state) do
    tasks = Services.Task.as_string(list_id)

    """
    Task list ID: `#{list_id}` (use this ID when invoking task management tools)

    Current task list:
    #{tasks}

    The `tasks_show_list` tool can be used to display these tasks in more
    detail, including detailed descriptions and statuses.
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

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
    # Note: Testing mode bypasses Services.Conversation, so no accumulated_tokens.
    # Memories won't fire in testing mode, which is acceptable since testing: is for
    # quick tool validation, not full conversation flow.
    # If we want memories in testing mode, we'd need to manually call update_memory_state.

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
    |> then(fn {:ok, %{response: msg} = response} ->
      UI.say(msg)

      response
      |> AI.Agent.tools_used()
      |> Enum.each(fn {tool, count} ->
        UI.report_step(tool, "called #{count} time(s)")
      end)

      log_usage(response)
    end)

    {:error, :testing}
  end
end
