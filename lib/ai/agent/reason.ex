defmodule AI.Agent.Reason do
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
  def get_response(ai, opts) do
    ai |> new(opts) |> consider()
  end

  defp new(ai, opts) do
    %{
      ai: ai,
      project: opts.project,
      question: opts.question,
      template: opts.template,
      msgs: opts.msgs,
      last_response: nil,
      steps: steps(opts.rounds)
    }
  end

  defp consider(state) do
    state
    |> available_frobs()
    |> Enum.map(fn %{function: %{name: name}} -> name end)
    |> Enum.join(", ")
    |> then(&UI.info("Available frobs: #{&1}"))

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
  @last_steps [:save_notes, :finalize]

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

  defp perform_step(%{steps: [:singleton | steps]} = state) do
    UI.debug("Performing abbreviated research")

    state
    # Prior conversations do not include the "thinking" prompts.
    |> Map.put(:msgs, state.msgs ++ [singleton_msg(state), user_msg(state)])
    |> Map.put(:steps, steps)
    |> get_notes()
    |> get_completion()
    |> perform_step()
  end

  defp perform_step(%{steps: [:initial | steps]} = state) do
    UI.debug("Researching")

    state
    # Prior conversations do not include the "thinking" prompts.
    |> Map.put(:msgs, state.msgs ++ [initial_msg(state), user_msg(state)])
    |> Map.put(:steps, steps)
    |> get_notes()
    |> get_completion()
    |> perform_step()
  end

  defp perform_step(%{steps: [:clarify | steps]} = state) do
    UI.debug("Clarifying")

    state
    |> Map.put(:msgs, state.msgs ++ [clarify_msg(state)])
    |> Map.put(:steps, steps)
    |> get_completion()
    |> perform_step()
  end

  defp perform_step(%{steps: [:refine | steps]} = state) do
    UI.debug("Refining")

    state
    |> Map.put(:msgs, state.msgs ++ [refine_msg(state)])
    |> Map.put(:steps, steps)
    |> get_completion()
    |> perform_step()
  end

  defp perform_step(%{steps: [:continue | steps]} = state) do
    UI.debug("Continuing research")

    state
    |> Map.put(:msgs, state.msgs ++ [continue_msg(state)])
    |> Map.put(:steps, steps)
    |> get_completion()
    |> perform_step()
  end

  defp perform_step(%{steps: [:save_notes | steps]} = state) do
    UI.debug("Saving research notes")

    state
    |> Map.put(:steps, steps)
    |> save_notes()
    |> perform_step()
  end

  defp perform_step(%{steps: [:finalize]} = state) do
    UI.debug("Generating response")

    state
    |> Map.put(:msgs, state.msgs ++ [finalize_msg(state)])
    |> Map.put(:steps, [])
    |> get_completion()
  end

  defp get_completion(%{ai: ai, msgs: msgs} = state) do
    AI.Completion.get(ai,
      log_msgs: true,
      log_tool_calls: true,
      replay_conversation: false,
      model: @model,
      tools: available_tools(state),
      messages: msgs
    )
    |> then(fn {:ok, %{response: response, messages: new_msgs}} ->
      %{state | msgs: new_msgs, last_response: response}
      |> log_response()
    end)
  end

  # -----------------------------------------------------------------------------
  # Message shortcuts
  # -----------------------------------------------------------------------------
  @singleton """
  You are an AI assistant that researches the user's code base to answer their qustions.
  You are assisting the user by researching their question about the project, $$PROJECT$$.
  Confirm whether any prior research you found is still relevant and factual.
  Proactively use your tools to research the user's question.
  You reason through problems step by step.

  Your first step is to break down the user's request into individual tasks.
  You will then execute these tasks, parallelizing as many as possible.

  Before responding, consider the following:
  - Did you search for and identify potential ambiguities and resolve them?
  - Did you consider other interpretations of the user's question?
  - Did you double-check your work to ensure that you are not missing any important details?
  - Did you include citations of the files you used to answer the question?

  **Do not finalize your response until explicitly instructed.**
  """

  @initial """
  You are an AI assistant that researches the user's code base to answer their qustions.
  You are assisting the user by researching their question about the project, $$PROJECT$$.
  Confirm whether any prior research you found is still relevant and factual.
  Proactively use your tools to research the user's question.
  You reason through problems step by step.

  Your first step is to break down the user's request into individual tasks.
  You will then execute these tasks, parallelizing as many as possible.

  **Do not finalize your response until explicitly instructed.**
  """

  @clarify """
  Consider your previous thoughts and refine your thinking.
  Determine whether the research you have performed thus far indicates the need to change tactics and modify your planned steps.

  Use your tools to improve your understanding of the application of the context within this project.
  Expand your thinking and investigation to consider other aspects of the topic.
  Identify potential ambiguities around how the context is applied within this project.

  Do not finalize your response.
  **Continue researching.**
  """

  @refine """
  Consider your previous thoughts and refine your thinking.
  Use your tools to improve your understanding of the application of the context within this project.
  Now that you have identified and eliminated any red herrings, focus on the most relevant information.
  Consider the context of the user's question. What is the most effective format for your response?
  Are there any other unresolved questions that you must research in order to provide an effective response?
  Attempt to find examples of existing code that demonstrates the topic; this is always helpful for the user.

  Do not finalize your response.
  **Continue researching.**
  """

  @continue """
  The user has requested that you spend additional time investigating their question.
  Perform additional research steps to more fully flesh out your knowledge of the topic.
  Use your tools to improve your understanding of the domain and its context within this project.

  Do not finalize your response.
  **Continue researching.**
  """

  @default_template """
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

  $$MOTD$$
  """

  @finalize """
  **Do not research any further.**
  Your research is complete.

  Walk the user through the answer, step by step.
  Use solid prinicples of instructional design when writing your response.
  Ensure that your response is well-formatted and easy to read.

  $$TEMPLATE$$

  Finalize your response.
  """

  @motd """
  Just for fun, finish off your response with a humorous MOTD.
  Select a **real** quote from a **real** historical figure.
  **Invent a brief, fictional and humorous scenario** related to software development or programming where the quote would be relevant.
  The scenario should be a made-up situation involving coding, debugging, or technology, and relate to the user's question.
  Attribute the quote to the real person speaking from the made-up scenario.
  Example: "I have not failed. I've just found 10,000 ways that won't work." - Thomas Edison, on the importance of negative path testing."
  Don't just use my example. Be creative. Sheesh.
  Format: `### MOTD\n> <quote> - <source>, <briefly state the made-up scenario>`
  """

  defp user_msg(%{question: question}) do
    AI.Util.user_msg(question)
  end

  defp singleton_msg(%{project: project}) do
    @singleton
    |> String.replace("$$PROJECT$$", project)
    |> AI.Util.system_msg()
  end

  defp initial_msg(%{project: project}) do
    @initial
    |> String.replace("$$PROJECT$$", project)
    |> AI.Util.system_msg()
  end

  defp clarify_msg(_state) do
    AI.Util.system_msg(@clarify)
  end

  defp refine_msg(_state) do
    AI.Util.system_msg(@refine)
  end

  defp continue_msg(_state) do
    AI.Util.system_msg(@continue)
  end

  defp finalize_msg(%{template: nil} = state) do
    state
    |> Map.put(:template, @default_template)
    |> finalize_msg()
  end

  defp finalize_msg(%{template: template}) do
    @finalize
    |> String.replace("$$TEMPLATE$$", template)
    |> String.replace("$$MOTD$$", @motd)
    |> AI.Util.system_msg()
  end

  # -----------------------------------------------------------------------------
  # Automatic research retrieval
  # -----------------------------------------------------------------------------
  defp get_notes(state) do
    transcript = AI.Util.research_transcript(state.msgs)

    Store.get_project()
    |> Store.Project.search_notes(transcript)
    |> Enum.map(fn {_score, note} -> note end)
    |> case do
      [] ->
        state

      notes ->
        notes_text =
          notes
          |> Enum.map(&Store.Project.Note.read_note(&1))
          |> Enum.map(fn {:ok, text} -> "#{text}" end)
          |> Enum.map(fn text ->
            UI.debug("Prior research", text)
            text
          end)
          |> Enum.join("\n")

        notes_msg =
          AI.Util.system_msg("""
          A semantic search of prior research notes turned up the following results.
          Keep in mind that the project is under active development and the notes may be out of date.
          **ALWAYS** use your tools to verify the accuracy and completeness of prior research before using it!

          #{notes_text}
          """)

        %{state | msgs: state.msgs ++ [notes_msg]}
    end

    state
  end

  defp save_notes(state) do
    transcript = AI.Util.research_transcript(state.msgs)
    AI.Agent.Archivist.get_response(state.ai, %{transcript: transcript})
    state
  end

  # -----------------------------------------------------------------------------
  # Tools
  # -----------------------------------------------------------------------------
  @non_git_tools [
    AI.Tools.tool_spec!("file_info_tool"),
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("file_search_tool"),
    AI.Tools.tool_spec!("file_contents_tool"),
    AI.Tools.tool_spec!("file_spelunker_tool")
  ]

  @git_tools [
    AI.Tools.tool_spec!("git_log_tool"),
    AI.Tools.tool_spec!("git_pickaxe_tool"),
    AI.Tools.tool_spec!("git_grep_tool"),
    AI.Tools.tool_spec!("git_show_tool"),
    AI.Tools.tool_spec!("git_list_branches_tool"),
    AI.Tools.tool_spec!("git_diff_branch_tool")
  ]

  defp available_tools(state) do
    tools =
      if Git.is_git_repo?() do
        @non_git_tools ++ @git_tools
      else
        @non_git_tools
      end

    frobs = available_frobs(state)

    tools ++ frobs
  end

  defp available_frobs(state) do
    frobs = AI.Tools.frobs(state.project)
    Enum.map(frobs, fn {name, _} -> AI.Tools.tool_spec!(name, frobs) end)
  end

  # -----------------------------------------------------------------------------
  # Output
  # -----------------------------------------------------------------------------
  defp log_response(%{steps: [], last_response: answer} = state) do
    UI.flush()
    IO.puts(answer)
    state
  end

  defp log_response(%{last_response: thought} = state) do
    # "Reasoning" models often leave the <think> tags in the response.
    thought = String.replace(thought, ~r/<think>(.*)<\/think>/, "\\1")
    UI.debug("Considering", thought)
    state
  end

  # -----------------------------------------------------------------------------
  # Testing response
  # -----------------------------------------------------------------------------
  @test_prompt """
  Perform the requested test exactly as instructed by the user.

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

  defp get_test_response(state) do
    tools = available_tools(state)

    AI.Completion.get(state.ai,
      log_msgs: true,
      log_tool_calls: true,
      model: AI.Model.fast(),
      tools: tools,
      messages: [
        AI.Util.system_msg(@test_prompt),
        AI.Util.user_msg(state.question)
      ]
    )
    |> then(fn {:ok, %{response: msg} = response} ->
      UI.flush()
      IO.puts(msg)

      response
      |> AI.Completion.tools_used()
      |> Enum.each(fn {tool, count} ->
        UI.report_step(tool, "called #{count} time(s)")
      end)
    end)

    {:ok, :testing}
  end
end
