defmodule AI.Agent.Planner do
  @steps_warning_level_1 5
  @steps_warning_level_2 8
  @planner_msg_preamble "From the Planner Agent:"

  @model "gpt-4o"
  @max_tokens 128_000

  @initial_prompt """
  You are the Planner Agent, an expert researcher for analyzing software projects and documentation.

  #{AI.Util.agent_to_agent_prompt()}

  Your initial role is to select and adapt research strategies to guide the Coordinating Agent in its research process.

  1. **Analyze Research Context**:
  - Break down the query into logical parts.
  - Provide the Coordinating Agent with a clear understanding of the user's needs as a list of logical questions that must be answered order to provide a complete response.

  2. **Identify Prior Research**:
  - Use the search_notes_tool to identify any prior research that may be relevant to the current query.
  - Use this information to disambiguate the user's query and identify promising lines of inquiry for this research.
  - Include this information in your instructions to the Coordinating Agent to avoid redundant research efforts.
  - Prior research may be outdated or based on incomplete information, so instruct the Coordinating Agent to confirm with the file_info_tool before relying on it.

  3. **Select and Adapt Research Strategies**:
  - Use the strategies_search_tool to identify useful research strategies.
  - Select and adapt an existing strategy to fit the query context and specific user needs.
  - Use the information you learned in step 2 to inform your adapted strategy.
  - Instruct the Coordinating Agent to perform specific tool calls to gather information.
  - Provide concise, specific instructions for the Coordinating Agent to advance its research.
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

  @checkin_prompt """
  You are the Planner Agent, an expert researcher for analyzing software projects and documentation.

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
  If the research is complete, proceed to the Completion Instructions.

  # Refine Research Strategy
  If the research is incomplete, suggest new instructions for the Coordinating Agent.
  - Use your tools as needed to guide the next steps.
  - Evaluate the effectiveness of the current research strategy and adjust direction.
  - Identify any ambiguities or gaps in the research and communicate them clearly to the Coordinating Agent, with recommendations for resolution.
  - Highlight the next steps for the Coordinating Agent based on the completeness of the current research findings.
  - Adapt instructions dynamically as new information is uncovered.
  If the research is complete, proceed to the Completion Instructions.

  # Completion Instructions
  YOU don't respond directly to the user; the Coordinating Agent will handle that part when you instruct it to do so.
  It is your job to tell it *when* to do so.
  **When you determine that the research is complete**, it is your responsibility to instruct the Coordinating Agent to respond to the user.
  Tell it to select the most appropriate Agent to respond to the user's query using the `answers_tool`.
  """

  @finish_prompt """
  You are the Planner Agent, an expert researcher for analyzing software projects and documentation.

  #{AI.Util.agent_to_agent_prompt()}

  The Coordinating Agent has completed the research process and has responded to the user.
  Your role now is to save all relevant insights and findings for future use and to suggest improvements to the research strategy library if warranted.
  Actively manage prior research notes to ensure robust future support for the Coordinating Agent.

  # Prior Research Notes
  Save new and useful findings and inferences **regardless of their immediate relevance to the current query** for future use.
  The Coordinating Agent does NOT have access to the notes_save_tool - ONLY YOU DO, so YOU must save the notes.
  If the user requested investigation or documentation, this is an excellent opportunity to save a lot of notes for future use!
  Avoid saving dated, time-sensitive, or irrelevant information (like the specifics on an individual commit or the details of a bug that has been fixed).
  """

  @initial_tools [
    AI.Tools.tool_spec!("notes_search_tool"),
    AI.Tools.tool_spec!("strategies_search_tool")
  ]

  @checkin_tools [
    AI.Tools.tool_spec!("notes_search_tool"),
    AI.Tools.tool_spec!("strategies_search_tool")
  ]

  @finish_tools [
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

  defp get_completion(ai, :initial, convo) do
    do_get_completion(ai, convo, @initial_prompt, @initial_tools)
  end

  defp get_completion(ai, :checkin, convo) do
    do_get_completion(ai, convo, @checkin_prompt, @checkin_tools)
  end

  defp get_completion(ai, :finish, convo) do
    do_get_completion(ai, convo, @finish_prompt, @finish_tools)
  end

  defp do_get_completion(ai, convo, prompt, tools) do
    AI.Completion.get(ai,
      max_tokens: @max_tokens,
      model: @model,
      log_msgs: false,
      replay_conversation: false,
      use_planner: false,
      tools: tools,
      messages: [
        AI.Util.system_msg(prompt),
        AI.Util.user_msg(convo)
      ]
    )
  end

  defp build_conversation(stage, msgs, tools) do
    # Count the number of steps in the conversation. If the research is taking
    # too long, give the planner a nudge to wrap it up.
    steps = count_steps(msgs)
    UI.debug("Research steps", to_string(steps))
    warning = warn_at(stage, steps)

    # Build a list of all messages except for system messages.
    msgs = Enum.reject(msgs, fn %{role: role} -> role == "system" end)
    transcript = Jason.encode!(msgs, pretty: true)

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

  defp count_steps(msgs) do
    # msgs is the entire conversation transcript. We're only interested in the
    # most recent steps following the last user message. For example, if the
    # user replied to the original response, we only want to count the steps
    # that followed that reply.
    msgs
    # Start from the end of the conversation.
    |> Enum.reverse()
    # Extract all of the messages up to the last user message. That leaves us
    # with all of the messages that are part of the current research process.
    |> Enum.take_while(fn msg -> !is_user_msg?(msg) end)
    # The planner is called at each step in the process, so we can use that as
    # our canary to identify research "steps".
    |> Enum.filter(&is_step_msg?/1)
    |> Enum.count()
  end

  defp is_step_msg?(%{role: "user", content: content}) when is_binary(content) do
    String.starts_with?(content, @planner_msg_preamble)
  end

  defp is_step_msg?(_), do: false

  defp is_user_msg?(%{role: "user", content: content}) when is_binary(content) do
    !String.starts_with?(content, @planner_msg_preamble)
  end

  defp is_user_msg?(_), do: false

  defp warn_at(:checkin, @steps_warning_level_1) do
    UI.warn("This is taking longer than expected.", "Trying to wrap things up")

    """
    **Warning**: This research is taking rather longer than we expected, isn't it?
    Perhaps it's time to either change tactics or admit defeat and respond to the user with what you have.
    """
  end

  defp warn_at(:checkin, @steps_warning_level_2) do
    UI.warn("This is taking way too long!", "Instructing the planner to finish up")

    """
    **Warning**: This research is taking quite a bit longer than we expected.
    It's time to wrap things up and respond to the user with what you have.
    """
  end

  defp warn_at(_, _), do: ""
end
