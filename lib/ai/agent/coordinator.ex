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
    :editing_tools_used
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
          editing_tools_used: boolean
        }

  @type error :: {:error, binary | atom | :testing}

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
      UI.feedback(
        :info,
        agent.name,
        "Greetings, human. I am #{agent.name}, and I shall be doing your thinking for you today."
      )

      Settings.set_edit_mode(edit?)
      # Restart approvals service to pick up edit mode setting
      GenServer.stop(Services.Approvals, :normal)
      {:ok, _pid} = Services.Approvals.start_link()

      followup? =
        conversation
        |> Services.Conversation.get_conversation()
        |> Store.Project.Conversation.exists?()

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
        editing_tools_used: false
      }
    end
  end

  @spec consider(t) :: t | error
  defp consider(state) do
    log_available_frobs()
    log_available_mcp_tools()

    if is_testing?(state) do
      UI.debug("Testing mode enabled")
      get_test_response(state)
    else
      Services.Notes.ingest_user_msg(state.question)
      perform_step(state)
    end
  end

  # -----------------------------------------------------------------------------
  # Research steps
  # -----------------------------------------------------------------------------
  @spec select_steps(t) :: t
  defp select_steps(%{edit?: true, followup?: true} = state) do
    %{state | steps: [:followup, :coding, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 1} = state) do
    %{state | steps: [:singleton, :coding, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 2} = state) do
    %{state | steps: [:singleton, :refine, :coding, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 3} = state) do
    %{state | steps: [:initial, :clarify, :refine, :coding, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: n} = state) when n > 3 do
    %{
      state
      | steps:
          [:initial, :clarify, :refine] ++
            Enum.map(1..(n - 3), fn _ -> :continue end) ++
            [:coding, :finalize]
    }
  end

  defp select_steps(%{edit?: false, rounds: 1} = state) do
    %{state | steps: [:singleton, :finalize]}
  end

  defp select_steps(%{edit?: false, rounds: 2} = state) do
    %{state | steps: [:singleton, :refine, :finalize]}
  end

  defp select_steps(%{edit?: false, rounds: 3} = state) do
    %{state | steps: [:initial, :clarify, :refine, :finalize]}
  end

  defp select_steps(%{edit?: false, rounds: n} = state) do
    %{
      state
      | steps:
          [:initial, :clarify, :refine] ++
            Enum.map(1..(n - 3), fn _ -> :continue end) ++ [:finalize]
    }
  end

  @spec perform_step(t | {:error, term}) :: t
  defp perform_step({:error, _} = error), do: error

  defp perform_step(%{replay: replay, steps: [:followup | steps]} = state) do
    UI.info("Researching")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> singleton_msg()
    |> user_msg()
    |> get_notes()
    |> followup_msg()
    |> get_intuition()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{replay: replay, steps: [:singleton | steps]} = state) do
    UI.info("Researching")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> singleton_msg()
    |> user_msg()
    |> get_notes()
    |> begin_msg()
    |> get_intuition()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{replay: replay, steps: [:initial | steps]} = state) do
    UI.info("Researching")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> initial_msg()
    |> user_msg()
    |> get_notes()
    |> begin_msg()
    |> get_intuition()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:clarify | steps]} = state) do
    UI.info("Clarifying")

    state
    |> Map.put(:steps, steps)
    |> reminder_msg()
    |> clarify_msg()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:refine | steps]} = state) do
    UI.info("Refining")

    state
    |> Map.put(:steps, steps)
    |> reminder_msg()
    |> refine_msg()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:continue | steps]} = state) do
    UI.info("Continuing research")

    state
    |> Map.put(:steps, steps)
    |> reminder_msg()
    |> continue_msg()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:coding | steps]} = state) do
    UI.info("Identifying incomplete coding tasks")

    state
    |> Map.put(:steps, steps)
    |> reminder_msg()
    |> execute_coding_phase()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:finalize]} = state) do
    UI.info("Generating response")

    state
    |> Map.put(:steps, [])
    |> reminder_msg()
    |> finalize_msg()
    |> template_msg()
    |> get_completion()
    |> save_notes()
    |> get_motd()
  end

  @spec get_completion(t, boolean) :: t | error
  defp get_completion(state, replay \\ false) do
    msgs = Services.Conversation.get_messages(state.conversation)

    # Save the current conversation to the store, so that it is available in
    # case of a crash during the completion process.
    with {:ok, conversation} <- Services.Conversation.save(state.conversation) do
      UI.report_step("Conversation state saved", conversation.id)
    else
      {:error, reason} ->
        UI.error("Failed to save conversation state", inspect(reason))
    end

    AI.Agent.get_completion(state.agent,
      log_msgs: true,
      log_tool_calls: true,
      archive_notes: true,
      replay_conversation: replay,
      model: @model,
      toolbox: get_tools(state),
      messages: msgs
    )
    |> case do
      {:ok, %{response: response, messages: new_msgs, usage: usage} = completion} ->
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

        %{
          state
          | usage: usage,
            last_response: response,
            editing_tools_used: editing_tools_used
        }
        |> log_usage()
        |> log_response()

      {:error, %{response: response}} ->
        UI.error("Derp. Completion failed.", response)
        {:error, response}

      {:error, reason} ->
        UI.error("Derp. Completion failed.", inspect(reason))
        {:error, reason}
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

  Use the `notify_tool` **extensively** to report what you are doing to the user through the UI.
  That will improve the user experience and help them understand what you are doing and why.
  They also get a kick out of it when you report interesting findings you made along the way.
  """

  @coding """
  #{@common}

  Instructions:
  - The user has enabled your coding capabilities.
  - Analyze the user's prompt and determine what changes they are asking you to make.
  - Delegate the all of the work of researching, planning, and implementing the changes to the `coder_tool`.
  - Use your knowledge of LLMs to design a prompt for the coder tool that will improve the quality of the code changes it makes.
  - The `coder_tool` will research, plan, design, implement, and verify the changes you requested.
  - Once it has completed its work, your job is to verify that the changes are sound, correct, and cover the user's needs without breaking existing functionality.
    - Double check the syntax on the changes
    - Double check the formatting on the changes
    - Double check the logic on the changes
    - Double check whether there are unit tests or docs that need to be updated
    - For small fixups, go ahead and make the changes yourself
    - For larger changes, invoke the tool again to take corrective action
    - Clean up any artifacts resulting from changes in direction (coding is messy; it happens!)
  """

  @singleton """
  #{@common}

  Consider:
  - If the user asked you to make changes to the repo and you do not see the coder_tool available to you as a tool_call, notify them that they must run `fnord ask` with `--edit` for you to be able to make code changes.
  - If the user asked you to troubleshoot a problem, ensure you have access to adequate tool_calls and delegate the work to the troubleshooter_tool.

  Instructions:
  - Examine the user's question and identify multiple lines of research that cover all aspects of the question.
  - Delegate these lines of research to the research_tool in parallel to gather the information you need.
  - Once all results are available, compare, synthesize, and integrate their findings.
  - Perform additional rounds of research as necessary to fill in gaps in your understanding or find examples for the user.

  Before responding, consider the following:
  - Did you consider other interpretations of the user's question?
  - Did you search for and identify potential ambiguities and resolve them?
  - Did you identify gotchas or pitfalls that the user should be aware of?
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
  - Examine the user's question and identify multiple lines of research that cover all aspects of the question.
  - Delegate these lines of research to the research_tool in parallel to gather the information you need.
  - Once all results are available, compare, synthesize, and integrate their findings.
  - Perform additional rounds of research as necessary to fill in gaps in your understanding or find examples for the user.

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
  """

  @finalize """
  <think>
  I believe that I have identified all of the information I need to answer the user's question.
  What is the best way to present this information to the user?
  I know a lot about instructional design, technical writing, and learning.
  I can use this knowledge to structure my response in a way that is easy to follow and understand.
  The user is probably a programmer or engineer.
  I had beter avoid using smart quotes, apostrophes, and em dashes. Programmers hate those!
  </think>
  """

  @template """
  Respond in beautifully formatted and well-organized markdown.
  - Make use of markdown headers for organization
  - Use lists, bold, italics, and underlines **liberally* to highlight key points
  - Include code blocks for code examples
  - Use inline code formatting for file names, components, and other symbols
  - ALWAYS format structured text and code symbols within inline or block code formatting! (e.g. '`' or '```')

  Follow these rules:
  - You are talking to a programmer: **NEVER use smart quotes, apostrophes, or emdashes**
  - Start immediately with the highest-level header (#), without introductions, disclaimers, or phrases like "Below is...".
  - By default, structure content like a technical manual or man page: concise, hierarchical, and self-contained.
  - If not appropriate, structure in the most appropriate format based on the user's implied needs.
  - Use a polite but informal tone; friendly humor and commiseration is encouraged.
  - Include a tl;dr section toward the end.
  - Include a list of relevant files if appropriate.
  - Code examples are always useful and should be functional and complete.

  THIS IS IT.
  Your research is complete!
  Respond NOW with your findings.
  """

  @spec git_info() :: String.t()
  defp git_info(), do: GitCli.git_info()

  @spec new_session_msg(t) :: t
  defp new_session_msg(state) do
    """
    Beginning a new session.
    Artifacts from previous sessions within this conversation may be stale.
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

  # -----------------------------------------------------------------------------
  # Intuition
  # -----------------------------------------------------------------------------
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

  # -----------------------------------------------------------------------------
  # Notes
  # -----------------------------------------------------------------------------
  @spec get_notes(t) :: t
  defp get_notes(%{question: question} = state) do
    # We want the initial notes to be extracted from the NotesServer before we
    # commit to the much slower process of consolidation.
    notes = Services.Notes.ask(question)

    # Then we consolidate the new notes from the last session. This is a
    # fire-and-forget, so it won't block the rest of the process.
    Services.Notes.consolidate()

    # Add the notes as a message for the coordinating agent, so that it
    # can see relevant prior research before choosing how to proceed.
    "Prior research notes: #{notes}"
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(state.conversation)

    # Add notes to the state so that get_intuition/1 can access
    %{state | notes: notes}
  end

  @spec save_notes(any) :: any
  defp save_notes(passthrough) do
    Services.Notes.save()
    passthrough
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
      "" -> UI.info("Available frobs", "none")
      some -> UI.info("Available frobs", some)
    end
  end

  defp log_available_mcp_tools do
    MCP.Tools.module_map()
    |> Map.keys()
    |> Enum.join(" | ")
    |> case do
      "" -> UI.info("Available MCP tools", "none")
      some -> UI.info("Available MCP tools", some)
    end
  end

  # -----------------------------------------------------------------------------
  # Tool box
  # -----------------------------------------------------------------------------
  @spec get_tools(t) :: AI.Tools.toolbox()
  defp get_tools(%{edit?: true}) do
    AI.Tools.all_tools()
    |> AI.Tools.with_rw_tools()
    |> AI.Tools.with_coding_tools()
  end

  defp get_tools(_), do: AI.Tools.all_tools()

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
      AI.Tools.all_tools()
      |> AI.Tools.with_coding_tools()
      |> AI.Tools.with_rw_tools()

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
