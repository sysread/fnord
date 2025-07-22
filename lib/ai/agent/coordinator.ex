defmodule AI.Agent.Coordinator do
  @moduledoc """
  This agent uses a combination of the reasoning features of the OpenAI o3-mini
  model as well as its own reasoning process to research and answer the input
  question.

  It is able to use most of the tools available and will save notes for future
  use before finalizing its response.
  """

  @model AI.Model.smart()

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    opts
    |> new()
    |> select_steps()
    |> consider()
  end

  defp new(opts) do
    with {:ok, conversation} <- Map.fetch(opts, :conversation),
         {:ok, edit?} <- Map.fetch(opts, :edit),
         {:ok, rounds} <- Map.fetch(opts, :rounds),
         {:ok, question} <- Map.fetch(opts, :question),
         {:ok, replay} <- Map.fetch(opts, :replay),
         {:ok, project} <- Store.get_project() do
      followup? =
        conversation
        |> ConversationServer.get_conversation()
        |> Store.Project.Conversation.exists?()

      %{
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
        current_step: 0,
        usage: 0,
        context: @model.context,
        notes: nil
      }
    end
  end

  defp consider(state) do
    Frobs.list()
    |> Enum.map(& &1.name)
    |> Enum.join(" | ")
    |> then(&UI.info("Available frobs", &1))

    if is_testing?(state) do
      UI.debug("Testing mode enabled")
      get_test_response(state)
    else
      NotesServer.ingest_user_msg(state.question)
      perform_step(state)
    end
  end

  # -----------------------------------------------------------------------------
  # Research steps
  # -----------------------------------------------------------------------------
  defp select_steps(%{edit?: true, followup?: true} = state) do
    %{state | steps: [:followup, :do_you_even_code_bro?, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 1} = state) do
    %{state | steps: [:singleton, :do_you_even_code_bro?, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 2} = state) do
    %{state | steps: [:singleton, :refine, :do_you_even_code_bro?, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: 3} = state) do
    %{state | steps: [:initial, :clarify, :refine, :do_you_even_code_bro?, :finalize]}
  end

  defp select_steps(%{edit?: true, followup?: false, rounds: n} = state) when n > 3 do
    %{
      state
      | steps:
          [:initial, :clarify, :refine] ++
            Enum.map(1..(n - 3), fn _ -> :continue end) ++
            [:do_you_even_code_bro?, :finalize]
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

  defp perform_step({:error, reason}) do
    {:error,
     """
     An error occurred while processing your request.

     #{reason}
     """}
  end

  defp perform_step(%{replay: replay, steps: [:followup | steps]} = state) do
    UI.debug("Performing abbreviated research")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> singleton_msg()
    |> maybe_coding_msg()
    |> user_msg()
    |> get_notes()
    |> followup_msg()
    |> get_intuition()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{replay: replay, steps: [:singleton | steps]} = state) do
    UI.debug("Performing abbreviated research")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> singleton_msg()
    |> maybe_coding_msg()
    |> user_msg()
    |> get_notes()
    |> begin_msg()
    |> get_intuition()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{replay: replay, steps: [:initial | steps]} = state) do
    UI.debug("Researching")

    state
    |> Map.put(:steps, steps)
    |> new_session_msg()
    |> initial_msg()
    |> maybe_coding_msg()
    |> user_msg()
    |> get_notes()
    |> begin_msg()
    |> get_intuition()
    |> get_completion(replay)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:clarify | steps]} = state) do
    UI.debug("Clarifying")

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
    UI.debug("Refining")

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
    UI.debug("Continuing research")

    state
    |> Map.put(:steps, steps)
    |> reminder_msg()
    |> continue_msg()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:do_you_even_code_bro? | steps]} = state) do
    UI.debug("Considering code changes")

    state
    |> Map.put(:steps, steps)
    |> reminder_msg()
    |> do_you_even_code_bro?()
    |> get_intuition()
    |> get_completion()
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:finalize]} = state) do
    UI.debug("Generating response")

    state
    |> Map.put(:steps, [])
    |> reminder_msg()
    |> finalize_msg()
    |> template_msg()
    |> get_completion()
    |> save_notes()
    |> get_motd()
  end

  defp get_completion(state, replay \\ false) do
    current_step = state.current_step + 1
    msgs = ConversationServer.get_messages(state.conversation)

    AI.Completion.get(
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
        ConversationServer.replace_msgs(new_msgs, state.conversation)

        completion
        |> AI.Completion.tools_used()
        |> Enum.map(fn {tool, count} -> "- #{tool}: #{count} invocation(s)" end)
        |> Enum.join("\n")
        |> then(&UI.debug("Tools used", &1))

        %{
          state
          | usage: usage,
            current_step: current_step,
            last_response: response
        }
        |> log_usage()
        |> log_response()

      {:error, %{response: response}} ->
        {:error, response}

      {:error, :context_length_exceeded} ->
        {:error,
         """
         The conversation has grown too long for the model to process, exceeding the length of its context window.
         Please start a new conversation.
         """}
    end
  end

  # -----------------------------------------------------------------------------
  # Message shortcuts
  # -----------------------------------------------------------------------------
  @singleton """
  You are an AI assistant that researches the user's code base to answer their qustions.
  You are assisting the user by researching their question about the project, "$$PROJECT$$".
  $$GIT_INFO$$

  Confirm whether any prior research you found is still relevant and factual.
  Proactively use your tools to research the user's question.
  You reason through problems step by step.

  Instructions:
  - Examine the user's question and identify multiple lines of research that cover all aspects of the question.
  - If the user asked you to make changes to the repo and you do not see the coder_tool available to you as a tool_call, notify them that they must run `fnord ask` with `--edit` for you to be able to make code changes.
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
  You are an AI assistant that researches the user's code base to answer their qustions.
  You are assisting the user by researching their question about the project, "$$PROJECT$$".
  $$GIT_INFO$$

  Confirm whether any prior research you found is still relevant and factual.
  Proactively use your research tools to research the user's question.
  You reason through problems step by step.

  Your first step is to break down the user's request into individual lines of research.
  You will then execute these tasks, parallelizing as many as possible.

  Instructions:
  - Examine the user's question and identify multiple lines of research that cover all aspects of the question.
  - If the user asked you to make changes to the repo and you do not see the coder_tool available to you as a tool_call, notify them that they must run `fnord ask` with `--edit` for you to be able to make code changes.
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

  @coding """
  Coding is enabled for this session at the user's request.
  THIS INDICATES THAT THE USER IS EXPECTING YOU TO MAKE PERSISTENT CODE CHANGES TO THE PROJECT.
  ONLY request confirmation from the user if they explicitly ask you to do so.

  # General rules:
  - Changes should be as minimal as possible
  - Changes should reflect the existing style and conventions of the project
  - Never make changes that the user did not explicitly request
  - Always double check your work; sometimes a change looks different once you see it in context

  # Guidelines:
  - If you are not sure about a change, ask the user for clarification
  - If your research identifies amgiguities the user did not consider, ask them for guidance
  - Look for existing code that implements a similar algorithm or pattern to ensure consistency with the project's style and conventions
  - Identify and update any unit tests that must be updated (both for the code you are changing as well as any upstream or downstream components that may be affected)
  - Add test coverage for your changes if it does not already exist
  - Check other unit tests to get a sense of conventions and style

  # Process:
  Code changes should be made one at a time, and only to a contiguous region of a single file.
  To make multiple changes, respond with a single tool_call request at a time.
  If you attempt to modify multiple ranges within the same file concurrently, the results will be unpredictable, as line numbers may change between calls, and there is an implicit race between concurrent tool calls.

  Inspect the file and identify the changes you wish to make.
  Split the changes into steps, where each step modifies a SINGLE, contiguous region of the file.
  For each step:
  1. Use the `coder_tool` to perform the change.
  2. Inspect the response to ensure that the change is correct.
  3. REREAD THE FILE to verify your changes.
  4. If available, use your tools to check syntax, run unit tests, and/or format the code to ensure the code is correct and consistent.
     Note that the coding agent has NO access to these tools, so YOU must call them after each change.
  5. If the code is incorrect or does not compile, restore the backup file using the `file_manage_tool` and try again, adjusting your arguments to the `file_edit_tool` as necessary.
  6. Repeat until the code is correct and complete.

  Repeat this process for each change.
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

  @do_you_even_code_bro? """
  <think>
  The user enabled editing tools, which probably means they expect me to make the changes myself.
  Let's see... what changes did the user ask me to make?
  I need to approach this thoughtfully.
  If the user asked me to implement something, I need to be sure that I've addressed all of the requirements.
  If I tried to make changes and they failed, I should try to correct my instructions to the coder_tool and try again.

  Let me think. Did I:
  - Call tools that can check the syntax of the code?
  - Call tools that can format the code to ensure it follows the project's conventions?
  - Call tools that can test the code to ensure it works as expected?
  </think>
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
  Format the response in markdown.

  Follow these rules:
    - You are talking to a programmer: **NEVER use smart quotes or apostrophes**
    - Start immediately with the highest-level header (#), without introductions, disclaimers, or phrases like "Below is...".
    - Use headers (##, ###) for sections, lists for key points, and bold/italics for emphasis.
    - By default, structure content like a technical manual or man page: concise, hierarchical, and self-contained.
    - If not appropriate, structure in the most appropriate format based on the user's implied needs.
    - Use a polite but informal tone; friendly humor and commiseration is encouraged.
    - Include a tl;dr section toward the end.
    - Include a list of relevant files if appropriate.
    - Avoid commentary or markdown-rendering hints (e.g., "```markdown").
    - Code examples are always useful and should be functional and complete, surrounded by markdown code fences.

  THS IS IT.
  Your research is complete!
  Respond NOW with your findings in the requested format.
  """

  defp git_info() do
    with {:ok, root} <- Git.git_root(),
         {:ok, branch} <- Git.current_branch() do
      """
      You are working in a git repository.
      The current branch is `#{branch}`.
      The git root is `#{root}`.
      """
    else
      {:error, :not_a_git_repo} -> "Note: this project is not under git version control."
    end
  end

  defp new_session_msg(state) do
    """
    Beginning a new session.
    Artifacts from previous sessions within this conversation may be stale.
    """
    |> AI.Util.system_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp singleton_msg(%{project: project} = state) do
    @singleton
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", git_info())
    |> AI.Util.system_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp initial_msg(%{project: project} = state) do
    @initial
    |> String.replace("$$PROJECT$$", project)
    |> String.replace("$$GIT_INFO$$", git_info())
    |> AI.Util.system_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp user_msg(%{question: question} = state) do
    question
    |> AI.Util.user_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp reminder_msg(%{question: question} = state) do
    "Remember the user's question: #{question}"
    |> AI.Util.system_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp followup_msg(state) do
    @followup
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp begin_msg(state) do
    @begin
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp maybe_coding_msg(%{edit?: false} = state), do: state

  defp maybe_coding_msg(%{edit?: true} = state) do
    @coding
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp clarify_msg(state) do
    @clarify
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp refine_msg(state) do
    @refine
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp continue_msg(state) do
    @continue
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp do_you_even_code_bro?(%{edit?: true} = state) do
    @do_you_even_code_bro?
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp do_you_even_code_bro?(state), do: state

  defp finalize_msg(state) do
    @finalize
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  defp template_msg(state) do
    @template
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    state
  end

  # -----------------------------------------------------------------------------
  # Intuition
  # -----------------------------------------------------------------------------
  defp get_intuition(state) do
    UI.begin_step("Cogitating")

    AI.Agent.Intuition.get_response(%{
      msgs: ConversationServer.get_messages(state.conversation),
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
        |> ConversationServer.append_msg(state.conversation)

        state

      {:error, reason} ->
        UI.error("Derp. Cogitation failed.", inspect(reason))
        state
    end
  end

  # -----------------------------------------------------------------------------
  # Notes
  # -----------------------------------------------------------------------------
  defp get_notes(%{question: question} = state) do
    # We want the initial notes to be extracted from the NotesServer before we
    # commit to the much slower process of consolidation.
    notes = NotesServer.ask(question)

    # Then we consolidate the new notes from the last session. This is a
    # fire-and-forget, so it won't block the rest of the process.
    NotesServer.consolidate()

    # Add the notes as a message for the coordinating agent, so that it
    # can see relevant prior research before choosing how to proceed.
    "Prior research notes: #{notes}"
    |> AI.Util.system_msg()
    |> ConversationServer.append_msg(state.conversation)

    # Add notes to the state so that get_intuition/1 can access
    %{state | notes: notes}
  end

  defp save_notes(state) do
    NotesServer.save()
    state
  end

  # -----------------------------------------------------------------------------
  # MOTD
  # -----------------------------------------------------------------------------
  defp get_motd(state) do
    with {:ok, motd} <- AI.Agent.MOTD.get_response(%{prompt: state.question}) do
      %{state | last_response: state.last_response <> "\n\n" <> motd}
    else
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
    UI.debug("Considering", thought)
    state
  end

  defp log_usage(usage) when is_integer(usage) do
    UI.log_usage(@model, usage)
  end

  defp log_usage(%{usage: usage} = state) do
    log_usage(usage)
    state
  end

  # -----------------------------------------------------------------------------
  # Tool box
  # -----------------------------------------------------------------------------
  defp get_tools(%{edit?: true}) do
    AI.Tools.all_tools()
    |> Map.values()
    |> Enum.concat([
      AI.Tools.File.Manage,
      # AI.Tools.File.Edit,
      AI.Tools.Coder
    ])
  end

  defp get_tools(_) do
    AI.Tools.all_tools()
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
        - The git_diff_branch_tool requires a branch name, which can be obtained from the git_list_branches_tool
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

  defp is_testing?(%{question: question}) do
    question
    |> String.downcase()
    |> String.starts_with?("testing:")
  end

  defp get_test_response(%{project: project} = state) do
    AI.Completion.get(
      log_msgs: true,
      log_tool_calls: true,
      model: AI.Model.fast(),
      toolbox: get_tools(state),
      messages: [
        @test_prompt
        |> String.replace("$$PROJECT$$", project)
        |> String.replace("$$GIT_INFO$$", git_info())
        |> AI.Util.system_msg(),
        AI.Util.user_msg(state.question)
      ]
    )
    |> then(fn {:ok, %{response: msg, usage: usage} = response} ->
      UI.say(msg)

      response
      |> AI.Completion.tools_used()
      |> Enum.each(fn {tool, count} ->
        UI.report_step(tool, "called #{count} time(s)")
      end)

      log_usage(usage)
    end)

    {:ok, :testing}
  end
end
