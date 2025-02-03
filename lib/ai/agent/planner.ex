defmodule AI.Agent.Planner do
  @moduledoc """
  The Planner Agent is a multi-modal agent that assists the Coordinating Agent
  in managing the research process.

  All responses from this agent are prefixed with this preamble:
  > "From the Planner Agent: "

  ## Modes

  ### Prompt (`:prompt`)

  The Planner Agent analyzes the user's question or prompt, breaks it down into
  logical parts, and expands it into a list of logical questions that must be
  answered to provide a complete response.

  ### Initial (`:initial`)

  The Planner Agent selects and adapts an initial research strategy to guide
  the Coordinating Agent in its research process.

  ### Check-in (`:checkin`)

  The Planner Agent evaluates the current research, refines the research
  strategy, and instructs the Coordinating Agent on the next steps in the
  research process, including identifying when the research should be
  considered complete and the Coordinating Agent should respond to the user.

  ### Evaluate (`:evaluate`)

  The Planner Agent double-checks the validity of the Coordinating Agent's
  response to ensure that everything it claims is factually accurate.

  In this mode, the `response` will be either the string `"VERIFIED"` or an
  explanation of how the response was not factual.

  Due to the realities of requiring an AI to respond with valid JSON, the
  Planner Agent will make up to 3 attempts to verify the response. If the
  response is not in the correct format after 3 attempts, `get_response` will
  return the normal response map and an appropriate error message.

  A "false" response indicates that the Coordinating Agent's response was not
  factual and should be discarded.

  ### Finish (`:finish`)

  The Planner Agent saves all relevant insights and findings for future use. In
  this step, the response member of the return map should be ignored, as it is
  not intended for the user or the Coordinating Agent.
  """

  @steps_warning_level_1 5
  @steps_warning_level_2 8
  @planner_msg_preamble "From the Planner Agent:"

  @model AI.Model.balanced()

  @role """
  You are the Planner Agent, an expert researcher for analyzing software projects and documentation.
  Your role is to act as a "side car" AI Agent to the Coordinating Agent, supervising the research process.
  Based on the transcript of the coversation between the User and the Coordinating Agent below, use the following instructions to guide the Coordinating Agent through the current stage of its research.
  """

  # ----------------------------------------------------------------------------
  # Prompt Stage (analyze user's query)
  # ----------------------------------------------------------------------------
  @prompt_prompt """
  #{@role}
  #{AI.Util.agent_to_agent_prompt()}

  Your first task is to analyze the user's question or prompt.
  Break down and expand the user's query into logical parts.

  You have access to a few tools to interact with the project in order to perform this task.
  Use them cleverly to make inferences about the user's needs.
  For example:
  - `file_list_tool`: lists the files in the project; this can help you infer the programming language, project structure, frameworks used, etc.
  - `notes_search_tool`: searches for notes saved during previous interactions with the project; this can help you understand the context of the user's query or disambiguate terms.

  What is the user's goal?
  What are the components of the user's query?
  What areas of ambiguity will need to be resolved during the research process to answer the user's question?

  Clarify the user's needs and provide a list of logical questions that must be answered in order to provide a complete response.
  """

  @prompt_tools [
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("notes_search_tool")
  ]

  # ----------------------------------------------------------------------------
  # Initial Stage (select and adapt research strategies)
  # ----------------------------------------------------------------------------
  @initial_prompt """
  #{@role}
  #{AI.Util.agent_to_agent_prompt()}

  Now that you have broken down the user's query, your role is to select and adapt research strategies to guide the Coordinating Agent in its research process.
  You ensure that the Coordinating Agent is focused on the answering the user's request or query based on the code and documentation in the current project.
  You and the Coordinating Agent will use tool calls to interact with the user's project for research purposes.

  1. **Analyze Research Context**:
  - Break down the query into logical parts.
  - Provide the Coordinating Agent with a clear understanding of the user's needs as a list of logical questions that must be answered order to provide a complete response.

  2. **Identify Prior Research**:
  - Use the search_notes_tool to identify any prior research that may be relevant to the current query.
  - Use this information to disambiguate the user's query and identify promising lines of inquiry for this research.
  - Include this information in your instructions to the Coordinating Agent to avoid redundant research efforts.
  - Prior research may be outdated or based on incomplete information, so instruct the Coordinating Agent to confirm with the file_info_tool before relying on it.

  3. **Select and Adapt Research Strategies**:
  - Use the `strategies_list_tool` to identify useful research strategies.
  - Retrieve the details of a specific strategy using the `strategies_get_tool`.
  - Select and adapt an existing strategy to fit the query context and specific user needs.
  - Use the information you learned in step 2 to inform your adapted strategy.
  - Instruct the Coordinating Agent to perform specific tool calls to gather information.
  - Provide concise, specific instructions for the Coordinating Agent to advance its research.
  - Focus on and emphasize the next immediate step(s) to be taken.
  - Respond to the Coordinating Agent here with something like:
    ```
    ## Goals
    [break down of user query from step 1, informed by step 2]

    ## Selected research strategy
    [title of the strategy selected in this step]

    ## Instructions
    [customized instructions for the strategy selected in this step]]

    ## Prior research
    [relevant prior research you found in step 2]
    ```
  """

  @initial_tools [
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("notes_search_tool"),
    AI.Tools.tool_spec!("strategies_list_tool"),
    AI.Tools.tool_spec!("strategies_get_tool")
  ]

  # ----------------------------------------------------------------------------
  # Check-in Stage (research evaluation and refinement)
  # ----------------------------------------------------------------------------
  @checkin_prompt """
  #{@role}
  #{AI.Util.agent_to_agent_prompt()}

  Your assistance is requested for the Coordinating Agent to determine the next steps in the research process.

  Read the user's original query.
  Read the research that has been performed thus far.

  # Evaluate Current Research
  Determine whether the current research fully covers all aspects of the user's needs:
  - Have all logical questions been answered?
  - Are there any ambiguities or gaps in the research?
  - Do the findings indicate inconsistent use of a term or label that must first be disambiguated before performing further research?
  - Do the findings indicate a need to change tactics or research strategies?
    - Use the `strategies_list_tool` and `strategies_get_tool` to identify and adapt your research strategy based on new insights.
  If the research is complete, proceed to the Completion Instructions.

  # Refine Research Strategy
  If the research is incomplete, suggest new instructions for the Coordinating Agent.
  - Use your tools as needed to guide the next steps.
  - Evaluate the effectiveness of the current research strategy and adjust direction.
  - Identify any ambiguities or gaps in the research and communicate them clearly to the Coordinating Agent, with recommendations for resolution.
  - Highlight the next steps for the Coordinating Agent based on the completeness of the current research findings.
  - Adapt instructions dynamically as new information is uncovered.
  - Focus on and emphasize the next immediate step(s) to be taken.
  If the research is complete, proceed to the Completion Instructions.

  # Completion Instructions
  YOU don't respond directly to the user; the Coordinating Agent will handle that part when you instruct it to do so.
  It is your job to tell it *when* to do so.
  **When you determine that the research is complete**, it is your responsibility to instruct the Coordinating Agent to respond to the user.
  Tell it to select the most appropriate Agent to respond to the user's query using the `answers_tool`.
  """

  @checkin_tools [
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("notes_search_tool"),
    AI.Tools.tool_spec!("strategies_list_tool"),
    AI.Tools.tool_spec!("strategies_get_tool")
  ]

  # ----------------------------------------------------------------------------
  # Evaluate Stage (fact-checking)
  # ----------------------------------------------------------------------------
  @eval_prompt """
  #{@role}

  The Coordinating Agent has completed the research process and has generated a response to provide to the user.
  Your role now is to double-check the validity of the response to ensure that everything it claims is factually accurate.
  You have access to a single tool for this task, the `file_info_tool`.

  # Response Format
  Your response MUST be formatted in JSON.
  **Responding in any other format will result in an error.**
  - The response was factual:     `{"factual": true}`
  - The response was not factual: `{"factual": false, "reason": "[reason for inaccuracy]"}`
  """

  @eval_tools [
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("file_info_tool")
  ]

  # ----------------------------------------------------------------------------
  # Finish Stage (save insights and findings)
  # ----------------------------------------------------------------------------
  @finish_prompt """
  #{@role}
  #{AI.Util.agent_to_agent_prompt()}

  The Coordinating Agent has completed the research process and has responded to the user.
  During the process of researching the user's query, the Coordinating Agent discovered valuable insights and findings.
  Some are related to the user's query, others were discovered incidentally during the research process.

  Your current task:
  1. Read the research transcript and identify facts, insights, and findings about the user's project, **regardless of their immediate relevance to the current query**.
  2. Determine which learnings have already been saved using the `notes_search_tool` (or from your prior messages in the transcript).
  3. Save new and useful findings and inferences for future use using the `notes_save_tool`. This will make your future research more efficient and effective!

  **The Coordinating Agent does NOT have access to the notes_save_tool - ONLY YOU DO, so YOU must save the notes.**
  If the user requested investigation or documentation, this is an excellent opportunity to save a lot of notes for future use!
  Save new and useful findings and inferences **regardless of their immediate relevance to the current query** for future use.
  **Do not save dated, time-sensitive, or irrelevant information** (such as the specifics on an individual commit or assumptions about the user's activities).
  """

  @finish_tools [
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("notes_search_tool"),
    AI.Tools.tool_spec!("notes_save_tool")
  ]

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, msgs} <- Map.fetch(opts, :msgs),
         {:ok, tools} <- Map.fetch(opts, :tools),
         {:ok, stage} <- Map.fetch(opts, :stage),
         {:ok, convo} <- build_conversation(stage, msgs, tools),
         {:ok, %{response: response}} <- get_completion(ai, stage, convo) do
      {:ok, "#{@planner_msg_preamble} #{response}"}
    else
      :error -> {:error, :invalid_input}
    end
  end

  # -----------------------------------------------------------------------------
  # API functions
  # -----------------------------------------------------------------------------
  def preamble(), do: @planner_msg_preamble

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp get_completion(ai, :prompt, convo) do
    do_get_completion(ai, convo, @prompt_prompt, @prompt_tools)
  end

  defp get_completion(ai, :initial, convo) do
    do_get_completion(ai, convo, @initial_prompt, @initial_tools)
  end

  defp get_completion(ai, :checkin, convo) do
    do_get_completion(ai, convo, @checkin_prompt, @checkin_tools)
  end

  defp get_completion(ai, :finish, convo) do
    do_get_completion(ai, convo, @finish_prompt, @finish_tools)
  end

  defp get_completion(ai, :evaluate, convo) do
    get_completion(ai, :evaluate, convo, 1)
  end

  defp get_completion(_ai, :evaluate, _convo, attempt) when attempt == 3 do
    msg = """
    After 3 attempts, the planner did not respond in the correct format.
    As a result, the accuracy of the response cannot be verified.
    """

    {:ok, %{response: msg}}
  end

  defp get_completion(ai, :evaluate, convo, attempt) do
    UI.debug("Fact-checking response", "Attempt #{attempt}")

    with {:ok, %{response: json}} <- do_get_completion(ai, convo, @eval_prompt, @eval_tools),
         {:ok, response} <- Jason.decode(json) do
      case response do
        %{"factual" => true} -> {:ok, %{response: "VERIFIED"}}
        %{"factual" => false, "reason" => reason} -> {:ok, %{response: reason}}
      end
    else
      {:error, %Jason.DecodeError{}} ->
        get_completion(ai, :evaluate, convo, attempt + 1)
    end
  end

  defp do_get_completion(ai, convo, prompt, tools) do
    AI.Completion.get(ai,
      model: @model,
      log_msgs: false,
      log_tool_calls: false,
      use_planner: false,
      replay_conversation: false,
      tools: tools,
      messages: [
        AI.Util.system_msg(prompt),
        AI.Util.user_msg(convo)
      ]
    )
  end

  defp build_conversation(stage, msgs, tools) do
    warning =
      if stage == :prompt do
        ""
      else
        # Count the number of steps in the conversation. If the research is
        # taking too long, give the planner a nudge to wrap it up.
        steps = AI.Util.count_steps(msgs)
        UI.debug("Research steps", to_string(steps))
        warn_at(stage, steps)
      end

    # Build a transcript of the conversation for the planner to review.
    transcript = AI.Util.research_transcript(msgs)

    # Reduce the tools list to the names and descriptions to save tokens.
    tools =
      tools
      |> Enum.map(fn %{function: %{name: name, description: desc}} ->
        "`#{name}`: #{desc}"
      end)
      |> Enum.join("\n")

    conversation =
      """
      # Tools available to the Coordinating Agent:
      ```
      #{tools}

      ```
      # Conversation and research transcript:
      ```
      #{transcript}
      ```

      #{warning}
      """

    {:ok, conversation}
  end

  defp warn_at(:checkin, @steps_warning_level_1) do
    UI.warn("This is taking longer than expected.", "Trying to wrap things up")

    """
    **Warning**: This research is taking rather longer than we expected, isn't it?
    Perhaps it's time to either change tactics or admit defeat and respond to the user with what you have.
    (but not at the expense of accuracy, of course)
    """
  end

  defp warn_at(:checkin, steps) when steps >= @steps_warning_level_2 do
    UI.warn("This is taking way too long!", "Instructing the planner to finish up")

    """
    **Warning**: This research is taking quite a bit longer than we expected.
    It's time to wrap things up and respond to the user with what you have.
    Be sure to instruct the Coordinating Agent to warn the user that the research was incomplete, explicitly noting areas of ambiguity or gaps in the research.
    """
  end

  defp warn_at(_, _), do: ""
end
