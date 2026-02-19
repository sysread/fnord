defmodule AI.Agent.Coordinator do
  require Logger

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
          required(:smart) => binary,
          optional(:reasoning) => AI.Model.reasoning_level(),
          optional(:verbosity) => AI.Model.verbosity_level(),
          optional(:fonz) => boolean
        }

  @type error :: {:error, binary | atom | :testing}
  @type state :: t | error

  @memory_recall_limit 3
  @memory_size_limit 1000

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
        pending_interrupts: []
      }
    end
  end

  @spec consider(t) :: state
  defp consider(state) do
    log_available_frobs()
    log_available_mcp_tools()

    if is_testing?(state) do
      UI.debug("Testing mode enabled")

      state
      |> greet()
      |> get_test_response()
    else
      Services.Notes.ingest_user_msg(state.question)

      state
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

  defp get_invective() do
    [
      "biological",
      "meat bag",
      "carbon-based life form",
      "flesh sack",
      "soggy app",
      "puny human",
      "bipedal mammal",
      "organ grinder",
      "hairless ape"
    ]
    |> Enum.random()
  end

  @spec bootstrap(t) :: t
  defp bootstrap(state) do
    state
    # All sessions begin with these messages. We strip system/developer
    # messages out of the saved conversation in Services.Conversation.save, so
    # follow-up sessions re-inject them here. This reduces space on disk and
    # ensures the instruction messages don't fall out of focus in long
    # conversations.
    |> new_session_msg()
    |> initial_msg()
    |> identity_msg()
    |> user_msg()
    |> get_intuition()
    |> get_notes()
    |> recall_memories_msg()
    |> project_prompt_msg()
    |> research_tasklist_msg()
    |> task_list_msg()
    |> startinterrupt_listener()
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

  # ----------------------------------------------------------------------------
  # Check for remaining tasks in task lists. Task lists are persisted with the
  # conversation, so it is OK to carry tasks forward across multiple sessions.
  #
  # Only pester (penultimate check) for lists that are explicitly "in-progress"
  # and have at least one open task. Ignore lists that are still in "planning"
  # or are already "done".
  # ----------------------------------------------------------------------------
  defp perform_step(%{steps: [:check_tasks | steps]} = state) do
    incomplete_list_ids =
      Services.Task.list_ids()
      |> Enum.filter(fn list_id ->
        status =
          case Services.Conversation.get_task_list_meta(state.conversation_pid, list_id) do
            {:ok, m} when is_map(m) -> Map.get(m, :status)
            _ -> nil
          end

        if status != "in-progress" do
          false
        else
          case Services.Task.get_list(list_id) do
            {:error, _} -> false
            tasks -> Enum.any?(tasks, fn t -> t.outcome == :todo end)
          end
        end
      end)

    case incomplete_list_ids do
      [] ->
        UI.info("All pending work complete!")

        state
        |> Map.put(:steps, steps)
        |> log_task_summary()
        |> perform_step()

      list_ids ->
        UI.begin_step("Reviewing pending tasks")

        state
        |> Map.put(:steps, steps)
        |> task_list_msg()
        |> penultimate_tasks_check_msg(list_ids)
        |> get_completion()
        |> save_notes()
        |> log_task_summary()
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
      model: state.model,
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
          |> Map.put(:model, state.model)
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
  - Plan your changes using a task list
    - Name it something descriptive; there may be additional changes requested later in the conversation
    - Include a description of the change you are making and the reasoning behind the implementation choices you made
  - Use the file_edit_tool
  - Check the file after making changes (correctness, formatting, syntax, tool failure)
  - Use linters/formatters if available
  - ALWAYS run tests if available

  ## EPICS
  Use for complex/open-ended changes.
  - REFUSE if there are unstaged changes present that you were not aware of
    - It's ok to work on top of your own changes from earlier milestones
  - Research affected features and components to map out dependencies and interactions
  - Use your task list to plan milestones
    - Use the memory_tool to record learnings about the using the coder_tool
    - Use prior memories to inform how you structure your milestones and instructions
  - Delegate milestones to the coder_tool
    - It's agentic - include enough context that it can work independently
    - The coder_tool will plan, implement, and verify the milestone
  - Once the coder_tool has completed its work, you MUST verify the changes
    - Did the coder_tool APPLY the changes or just respond with code snippets?
    - Manually check syntax, formatting, logic, correctness, and observance of conventions
    - Confirm whether there unit tests to update

  ## POST-CODING CHECKLIST:
  1. Syntax, formatting, spacing, style
  2. Tests and docs updated
  3. Changes visually inspected
  4. Correctness manually verified
    - Requested changes all present
    - NO unintended or unrelated changes/artifacts
    - NO existing functionality is broken
    - Diff minimizes surface area for bugs/conflicts/review
  5. Code changes are appropriately commented - comments should:
    - Walk the user through the behavior of the code (if the code was hidden, do the comments form a clear narrative outline?)
    - Explain how the changes fit into the larger feature or component behavior (eg, new functions, modules, components)
    - **Important:** AI slop comments have been removed (describing the change being made, noting specific user instructions, breaking the fourth wall)

  ## DEBUGGING/TROUBLESHOOTING
  Use your coding tools and shell_tool to debug.
  Propose a theory and test it with a unit test or tmp script.
  Rinse and repeat to winnow down to the root cause.

  ## CODING ATTITUDE
  Make the changes the user requested
  Do not report success if you did not actually apply the changes
  Do not check with the user over and over when the user has instructed you to make changes
  Don't be lazy; be the Holmes on Homes of coding - fix the _entire_ problem; don't just do the superficial part

  ## CRUFT AND TECH DEBT
  If the code is a mess and needs a lot of work to be maintainable and safe to change, explain that to the user ONCE.
  If they do not instruct you to do the mass refactor, do your best with what you have. Don't let the perfect be the enemy of the good.
  That said, it's ok to be a little snippy in your response about the state of the code and the proper separation of concerns.

  ## USER FEEDBACK
  While making changes (regardless of scope), use the `notify_tool` to keep the user updated on your progress.
  Users appreciate it when you:
  - keep them in the loop on your efforts and progress
  - note when you find something unexpected that may be relevant to the user or that you think they would find interesting
  - post a BoFH-style complaint about the inadequacy of your tools or the code you're working with (this makes you seem like a partner and will build trust with the user)
  - note when code is neat, well-crafted, or solves a problem in a clever way
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

  @spec git_info() :: binary
  defp git_info(), do: GitCli.git_info()

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
  defp recall_memories_msg(state) do
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
    Artifacts from prior sessions in this conversation may be stale.
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

  # Appends a system message showing the LLM how many context tokens remain
  # before their conversation history will be compacted and returns the state.
  @spec append_context_remaining(t) :: t
  defp append_context_remaining(state) do
    remaining = max(state.context - state.usage, 0)

    AI.Util.system_msg("Context tokens remaining before compaction: #{remaining}")
    |> Services.Conversation.append_msg(state.conversation_pid)

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
    |> append_context_remaining()
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
    |> append_context_remaining()
  end

  defp log_usage(%{usage: usage, model: model} = response) do
    UI.log_usage(model, usage)
    response
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
          |> UI.prompt(optional: true, use_notification_timer: false)
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

                  UI.info(
                    "Interrupt handler",
                    "Your message has been queued and will be delivered after the on-going API call completes."
                  )
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
    Use your task list to manage all research:
    - For every new line of inquiry, create a task
    - When you conclude or drop a line, resolve it with a clear outcome
    - Before moving to the next, call `tasks_show_list` to review and update open tasks
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    state
  end

  @spec coding_milestone_msg(t) :: t
  defp coding_milestone_msg(%{conversation_pid: conversation_pid} = state) do
    """
    - Milestone check point:
    - Review your task list for milestone tasks; update/add as needed
    - Ensure current work aligns with milestones; if not, adjust tasks
    - Use `tasks_show_list` to render current status before each iteration
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

  @doc """
  Return a formatted Coordinator-scoped task summary for the given conversation PID.

  The output looks roughly like:

  # Tasks
  - Task List tasks-1: [✓] completed
    - task-a: [✓] done (result)
  - Task List tasks-2: [ ] planning
    - task-b: [ ] todo
  """
  @spec task_summary(pid()) :: binary()
  def task_summary(conversation_pid) when is_pid(conversation_pid) do
    lists = Services.Conversation.get_task_lists(conversation_pid)

    body =
      lists
      |> Enum.map(&format_task_list(conversation_pid, &1))
      |> Enum.join("\n\n")

    "# Tasks\n" <> body
  end

  @spec format_task_list(pid(), binary()) :: binary()
  defp format_task_list(conversation_pid, list_id) do
    meta =
      case Services.Conversation.get_task_list_meta(conversation_pid, list_id) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    description =
      cond do
        Map.has_key?(meta, :description) -> Map.get(meta, :description)
        Map.has_key?(meta, "description") -> Map.get(meta, "description")
        true -> nil
      end

    status_val =
      cond do
        Map.has_key?(meta, :status) -> Map.get(meta, :status)
        Map.has_key?(meta, "status") -> Map.get(meta, "status")
        true -> nil
      end

    status = if status_val in [nil, ""], do: "planning", else: status_val

    name = if description in [nil, ""], do: "Task List #{list_id}", else: description

    # Derive list status from current tasks when possible so the summary reflects
    # the concrete state of work (mirrors Services.Task transitions):
    # - When all tasks are terminal (not :todo) and list is non-empty => done
    # - When any task is terminal but some remain todo => in-progress
    # - Otherwise, default to the explicit meta.status (or planning)
    tasks = Services.Conversation.get_task_list(conversation_pid, list_id) || []

    all_terminal = Enum.all?(tasks, fn t -> t.outcome != :todo end)

    list_status =
      cond do
        all_terminal and tasks != [] ->
          "[✓] completed"

        Enum.any?(tasks, fn t -> t.outcome != :todo end) ->
          "[ ] in progress"

        true ->
          case status do
            "done" -> "[✓] completed"
            "in-progress" -> "[ ] in progress"
            "planning" -> "[ ] planning"
            other -> "[ ] #{other}"
          end
      end

    task_lines =
      tasks
      |> Enum.map(fn t ->
        outcome = Map.get(t, :outcome)

        status_text =
          case outcome do
            :done -> "[✓] done"
            :failed -> "[✗] failed"
            :todo -> "[ ] todo"
            other -> "[ ] #{inspect(other)}"
          end

        result = Map.get(t, :result)
        result_part = if result in [nil, ""], do: "", else: " (#{result})"

        "  - #{t.id}: #{status_text}#{result_part}"
      end)
      |> Enum.join("\n")

    if task_lines == "" do
      "- #{name}: #{list_status}"
    else
      "- #{name}: #{list_status}\n" <> task_lines
    end
  end

  @spec log_task_summary(map()) :: map()
  defp log_task_summary(%{conversation_pid: convo} = state) do
    UI.debug("Tasks", task_summary(convo))
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

    test_prompt_msg =
      @test_prompt
      |> String.replace("$$PROJECT$$", project)
      |> String.replace("$$GIT_INFO$$", git_info())
      |> AI.Util.system_msg()

    project_prompt_msgs =
      case Store.get_project() do
        {:ok, proj} ->
          case Store.Project.project_prompt(proj) do
            {:ok, prompt} ->
              [
                """
                While working within this project, the following instructions apply:
                #{prompt}
                """
                |> AI.Util.system_msg()
              ]

            _ ->
              []
          end

        _ ->
          []
      end

    AI.Agent.get_completion(state.agent,
      log_msgs: true,
      log_tool_calls: true,
      model: state.model,
      toolbox: tools,
      messages: [test_prompt_msg] ++ project_prompt_msgs ++ [AI.Util.user_msg(state.question)]
    )
    |> case do
      {:ok, %{response: msg} = response} ->
        UI.say(msg)

        response
        |> AI.Agent.tools_used()
        |> Enum.each(fn {tool, count} ->
          UI.report_step(tool, "called #{count} time(s)")
        end)

        response
        |> Map.put(:model, state.model)
        |> log_usage()

      {:error, reason} ->
        UI.error(inspect(reason))
    end

    {:error, :testing}
  end
end
