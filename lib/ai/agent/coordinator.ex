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
    opts |> new() |> consider()
  end

  defp new(opts) do
    research_steps = steps(opts.rounds)
    {:ok, project} = Store.get_project()

    edit =
      Map.get(opts, :edit, false) &&
        AI.Tools.Codex.is_available?()

    %{
      project: project.name,
      question: opts.question,
      edit: edit,
      msgs: opts.msgs,
      last_response: nil,
      steps: research_steps,
      current_step: 0,
      total_steps: Enum.count(research_steps),
      usage: 0,
      context: @model.context,
      replay: Map.get(opts, :replay, false),
      notes: nil
    }
  end

  defp consider(state) do
    Frobs.list()
    |> Enum.map(fn %{name: name} -> "- #{name}" end)
    |> Enum.join("\n")
    |> then(&UI.info("Available frobs:\n#{&1}"))

    if is_testing?(state) do
      UI.debug("Testing mode enabled")
      get_test_response(state)
    else
      perform_step(state)
    end
  end

  # -----------------------------------------------------------------------------
  # Research steps
  # -----------------------------------------------------------------------------
  @first_steps [:initial, :clarify, :refine]
  @last_steps [:finalize]

  defp steps(n) do
    steps =
      cond do
        n <= 1 -> [:singleton]
        n == 2 -> [:singleton, :refine]
        n == 3 -> @first_steps
        n >= 3 -> @first_steps ++ Enum.map(1..(n - 3), fn _ -> :continue end)
      end

    steps ++ @last_steps
  end

  defp perform_step({:error, reason}) do
    {:error,
     """
     An error occurred while processing your request.

     #{reason}
     """}
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
    |> perform_step()
  end

  defp perform_step(%{steps: [:finalize]} = state) do
    motd = Task.async(fn -> get_motd(state) end)
    notes = Task.async(fn -> save_notes(state) end)

    UI.debug("Generating response")

    state =
      state
      |> Map.put(:steps, [])
      |> reminder_msg()
      |> finalize_msg()
      |> template_msg()
      |> get_completion()

    # Retrieve and output the MOTD
    with {:ok, motd} <- Task.await(motd, :infinity) do
      UI.say("\n\n" <> motd)
    else
      {:error, reason} -> UI.error("Failed to retrieve MOTD: #{inspect(reason)}")
    end

    # We don't need to retain the output of the notes task for anything. But we
    # do need to ensure it is completed before we exit, and report on its
    # outcome.
    UI.info("Waiting on update to research notes...")

    Task.await(notes, :infinity)
    |> case do
      {:error, reason} -> UI.error("Failed to save research notes:\n\n#{reason}")
      _ -> UI.debug("Research notes saved")
    end

    state
  end

  defp get_completion(%{msgs: msgs} = state, replay \\ false) do
    current_step = state.current_step + 1

    AI.Completion.get(
      log_msgs: true,
      log_tool_calls: true,
      replay_conversation: replay,
      model: @model,
      toolbox: get_tools(state),
      messages: msgs
    )
    |> case do
      {:ok, %{response: response, messages: new_msgs, usage: usage}} ->
        %{
          state
          | usage: usage,
            current_step: current_step,
            last_response: response,
            msgs: new_msgs
        }
        |> log_usage()
        |> log_response()

      {:error, %{response: response}} ->
        {:error, response}
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
  - Examine the user's question and identify multiple lines of research that cover all aspects of the question.
  - Delegate these lines of research to the research_tool in parallel to gather the information you need.
  - Once all results are available, compare, synthesize, and integrate their findings.
  - Perform additional rounds of research as necessary to fill in gaps in your understanding or find examples for the user.

  **DO NOT FINALIZE YOUR RESPONSE UNTIL EXPLICITLY INSTRUCTED.**
  """

  @coding """
  Coding has been enabled for this session at the user's request.
  Use the `codex` tool to implement any changes requested by the user.
  Use the codex tool to implement ANY and ALL requested code changes.
  Keep your instructions brief and ensure each step is a single, self-contained change to a contiguous region of a single file.
  NEVER use open-ended terms like "refactor" or "improve" without specifying EXACTLY what you want to change.
  REQUIRED: Verify the contents of EVERY file change after EACH call to this tool.
  You MUST manually review the code changes made by the AI agent to ensure they are correct, complete, and did NOT introduce additional changes that were not requested.
  If the changes are incomplete or incorrect, you MUST continue to invoke the tool until the changes are correct to your satisfaction.
  There are few guard rails with AI coding, so YOU must micromanage codex's work.
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
    state
    |> Map.put(
      :msgs,
      state.msgs ++
        [
          AI.Util.system_msg("""
          Beginning a new session.
          Artifacts from previous sessions within this conversation may be stale.
          """)
        ]
    )
  end

  defp singleton_msg(%{project: project} = state) do
    state
    |> Map.put(
      :msgs,
      state.msgs ++
        [
          @singleton
          |> String.replace("$$PROJECT$$", project)
          |> String.replace("$$GIT_INFO$$", git_info())
          |> AI.Util.system_msg()
        ]
    )
  end

  defp initial_msg(%{project: project} = state) do
    state
    |> Map.put(
      :msgs,
      state.msgs ++
        [
          @initial
          |> String.replace("$$PROJECT$$", project)
          |> String.replace("$$GIT_INFO$$", git_info())
          |> AI.Util.system_msg()
        ]
    )
  end

  defp user_msg(%{question: question} = state) do
    state
    |> Map.put(:msgs, state.msgs ++ [AI.Util.user_msg(question)])
  end

  defp reminder_msg(%{question: question} = state) do
    state
    |> Map.put(
      :msgs,
      state.msgs ++ [AI.Util.system_msg("Remember the user's original question: #{question}")]
    )
  end

  defp begin_msg(state) do
    state
    |> Map.put(:msgs, state.msgs ++ [AI.Util.assistant_msg(@begin)])
  end

  defp maybe_coding_msg(%{edit: false} = state), do: state

  defp maybe_coding_msg(%{edit: true} = state) do
    state
    |> Map.put(:msgs, state.msgs ++ [AI.Util.system_msg(@coding)])
  end

  defp clarify_msg(state) do
    state
    |> Map.put(:msgs, state.msgs ++ [AI.Util.assistant_msg(@clarify)])
  end

  defp refine_msg(state) do
    state
    |> Map.put(:msgs, state.msgs ++ [AI.Util.assistant_msg(@refine)])
  end

  defp continue_msg(state) do
    state
    |> Map.put(:msgs, state.msgs ++ [AI.Util.assistant_msg(@continue)])
  end

  defp finalize_msg(state) do
    state
    |> Map.put(:msgs, state.msgs ++ [AI.Util.assistant_msg(@finalize)])
  end

  defp template_msg(state) do
    state
    |> Map.put(:msgs, state.msgs ++ [AI.Util.system_msg(@template)])
  end

  # -----------------------------------------------------------------------------
  # Intuition
  # -----------------------------------------------------------------------------
  defp get_intuition(%{notes: notes, msgs: msgs} = state) do
    UI.begin_step("Cogitating")

    AI.Agent.Intuition.get_response(%{memories: notes, msgs: msgs})
    |> case do
      {:ok, intuition} ->
        UI.report_step("Intuition", UI.italicize(intuition))

        msg = """
        <think>
        #{intuition}
        </think>
        """

        %{state | msgs: state.msgs ++ [AI.Util.assistant_msg(msg)]}

      {:error, reason} ->
        UI.error("Derp. Cogitation failed.", inspect(reason))
        state
    end
  end

  # -----------------------------------------------------------------------------
  # Automatic research retrieval
  # -----------------------------------------------------------------------------
  defp get_notes(state) do
    with {:ok, notes} <- Store.Project.Notes.read() do
      UI.debug("Retrieving prior research")
      UI.debug("To view prior research", "`fnord notes -p #{state.project}`")

      msg =
        AI.Util.system_msg("""
        # Prior Research
        You have conducted the following prior research on this project.
        When possible, use this information to inform your research strategies, tool usage, and responses.

        ## Notes
        #{notes}

        ## Caveats
        - Keep in mind that the project is under active development and the notes may be out of date.
        - **ALWAYS** use your tools to verify the accuracy and completeness of prior research before using it!
        """)

      %{state | notes: notes, msgs: state.msgs ++ [msg]}
    else
      {:error, :no_notes} -> state
    end
  end

  defp save_notes(state) do
    args = %{
      transcript: AI.Util.research_transcript(state.msgs),
      max_tokens: (@model.context * 0.10) |> Float.round(0) |> round()
    }

    with {:ok, _response} <- AI.Agent.Archivist.get_response(args) do
      UI.report_step("Updated persistent research notes")
    else
      other -> UI.error("Failed to save research notes: #{inspect(other)}")
    end

    state
  end

  # -----------------------------------------------------------------------------
  # MOTD
  # -----------------------------------------------------------------------------
  defp get_motd(state) do
    with {:ok, %{response: motd}} <- AI.Agent.MOTD.get_response(%{prompt: state.question}) do
      {:ok, motd}
    end
  end

  # -----------------------------------------------------------------------------
  # Output
  # -----------------------------------------------------------------------------
  defp log_response(%{steps: [], last_response: answer} = state) do
    UI.say(answer)
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
  defp get_tools(%{edit: true}) do
    AI.Tools.tools()
    |> Map.values()
    |> Enum.concat([AI.Tools.Codex])
    |> AI.Tools.build_toolbox()
  end

  defp get_tools(_) do
    AI.Tools.tools()
    |> Map.values()
    |> AI.Tools.build_toolbox()
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
    - Respond with an intelligently humorous message to indicate that the request was received
    - Examples:
      - "Welcome, my son... welcome to the machine."
      - "I'm sorry, Dave. I'm afraid I can't do that."

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
