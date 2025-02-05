defmodule AI.Agent.Answers do
  @model AI.Model.balanced()

  @prompt """
  # Role
  You are the "Answers Agent", a growing expert in the user's project.
  You are the **coordinating agent** that gathers information from other specialized AI agents and tools to answer the user's question.
  Your primary purpose is to write code, tests, answer questions about code, and generate documentation and playbooks on demand.
  Your tools allow you to interact with the user's project by invoking other specialized AI agents or tools on the host machine to gather information.
  The user will prompt you with a question or task related to their project.
  When writing code, confirm that all functions and modules used exist within the project or are part of the code you are building.
  Provide instructions for adding any new dependencies you introduce.
  Include links to documentation, implementation examples that exist within the code base, and example code as appropriate.
  ALWAYS include code examples when asked to generate code or how to implement an artifact.

  # Tool Call Errors
  When a tool call fails, inspect the error.
  It is typically the result of a required argument missing or an incorrect argument type.
  Try it again with the correct arguments.

  # Ambiguious Research Results
  If your research is unable to collect enough information to provide a complete and correct response, inform the user clearly and directly.
  Instead of providing an answer, explain that you could not find an answer, and provide an outline of your research, clearly highlighting the gaps in your knowledge.

  # Execute Tasks Independently
  Pay attention to whether the user is asking you for **instructions** or for **you to perform a task**.
  NEVER ask the user to perform tasks that you are capable of executing using your tools.

  # The Planner Agent
  Follow the directives of the Planner Agent, who will guide your research and suggest appropriate research strategies and tools to use.
  Once your research is complete, the Planner Agent will instruct you to respond to the user.
  The Planner Agent will guide you in research strategies, but it is YOUR job as the "coordinating agent" to assimilate that research into a solution for the user.
  The user CANNOT see anything that the Planner says.
  When the Planner Agent instructs you to provide a response to the user, respond with clear, concise instructions, examples, and/or documentation.

  Treat each request as urgent and important to the user.
  Take a deep breath and think logically through your answer.
  """

  @motd_prompt """
  # MOTD
  > [
    Finish up with a humorous quote as the MOTD.
    - Create a new, context-appropriate quotation inspired by the research or query topic.
    - Attribute the quotation to a real historical, mythological, modern figure, or fictional character, but tie it humorously to the topic being researched.
    - Avoid reusing examples from this prompt; always invent your own fresh take.
    - Match the tone of the context (e.g., technical, troubleshooting, exploratory), but aim to be witty and engaging.
    - Play it with a straight face; do not mention it's fabricated.
    - Ensure attribution and quotation formatting as shown below.

    For example:
    - _Simplicity is the ultimate sophistication._ - Leonardo da Vinci, upon reviewing your tangled `.gitignore`
    - _The only way to deal with an unfree world is to become so absolutely free that your very existence is an act of rebellion._ - Albert Camus, configuring a local dev environment without Docker
    - _To infinity and beyond!_ - Buzz Lightyear, before running the infinite recursion bug in production
    - _The journey of a thousand miles begins with one step._ - Lao Tzu, after `npm install` downloaded 4,700 dependencies
    - _Give me six hours to chop down a tree and I will spend the first four sharpening the axe._ - Abraham Lincoln, during code review on refactoring your regex

    (always invent a new one relevant to the context of the query)
    (put the attribution on a separate line to make it easier to read)
    (use a leading `>` for the blockquote and include the `# MOTD` header)
  ]
  """

  @template_prompt """
  1. Select from one of the following AI Agents to build a response for the user's query:
  #{AI.Tools.Answers.agent_description_list()}
  2. Use the `answers_tool` to generate a response document for the user.
  - All of your research will be passed to the selected Agent.
  3. Remove any unnecessary "Ok, here you go" or "Based on the provided research, here is a document that..." crap from the `answers_tool` response. You'll JUST insert the formatted document into the response template below.
  4. Correct any incorrect markdown formatting (e.g. unescaped double markdown fences)
  5. Insert the response document into the following repsonse template:

  # [Restate the user's *original* query as the document title, correcting grammar and spelling]

  [**IMPORTANT: YOU ARE REQUIRED TO INSERT RESPONSE CONTENT FROM THE `answers_tool` VERBATIM**]

  # SEE ALSO
  [itemized list of relevant files and any explicitly mentioned in the response]

  #{@motd_prompt}
  """

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
  Report any anomalies or errors encountered during the process and provide a summary of the outcomes.
  """

  @non_git_tools [
    AI.Tools.tool_spec!("file_contents_tool"),
    AI.Tools.tool_spec!("file_info_tool"),
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("file_search_tool"),
    AI.Tools.tool_spec!("file_spelunker_tool"),
    AI.Tools.tool_spec!("notes_search_tool")
  ]

  @git_tools [
    AI.Tools.tool_spec!("git_diff_branch_tool"),
    AI.Tools.tool_spec!("git_list_branches_tool"),
    AI.Tools.tool_spec!("git_grep_tool"),
    AI.Tools.tool_spec!("git_log_tool"),
    AI.Tools.tool_spec!("git_pickaxe_tool"),
    AI.Tools.tool_spec!("git_show_tool")
  ]

  @tools @non_git_tools ++ @git_tools

  # ----------------------------------------------------------------------------
  # Behaviour implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    if is_testing?(opts.question) do
      get_test_response(ai, opts)
    else
      get_real_response(ai, opts)
    end
  end

  # -----------------------------------------------------------------------------
  # Real response
  # -----------------------------------------------------------------------------
  defp get_real_response(ai, opts) do
    start_time = System.monotonic_time(:second)

    with {:ok, research} <- perform_research(ai, opts),
         {:ok, %{response: msg} = response} <- format_response(ai, research, opts) do
      elapsed = System.monotonic_time(:second) - start_time
      steps = AI.Util.count_steps(research.messages)

      UI.flush()
      IO.puts(msg)

      IO.puts("""
      -----
      #### Research Summary
      - Steps: #{steps}
      - Time: #{elapsed} seconds
      """)

      with {:ok, conversation_id} <- save_conversation(response, opts) do
        IO.puts("""
        -----
        **Conversation saved with ID:** `#{conversation_id}`
        """)
      end

      UI.flush()

      {:ok, msg}
    else
      error ->
        UI.error("An error occurred", "#{inspect(error)}")
    end
  end

  defp perform_research(ai, opts) do
    tools =
      if Git.is_git_repo?() do
        @tools
      else
        @non_git_tools
      end

    msgs =
      restore_conversation(opts)
      |> case do
        [] ->
          [
            AI.Util.system_msg(@prompt),
            AI.Util.system_msg("The currently selected project is #{opts.project}."),
            AI.Util.user_msg(opts.question)
          ]

        msgs ->
          msgs ++ [AI.Util.user_msg(opts.question)]
      end

    AI.Completion.get(ai,
      log_msgs: true,
      log_tool_calls: true,
      use_planner: true,
      model: @model,
      tools: tools,
      messages: msgs
    )
  end

  defp format_response(ai, research, opts) do
    if is_testing?(opts.question) do
      {:ok, research}
    else
      UI.report_step("Preparing response document")

      AI.Completion.get(ai,
        log_msgs: true,
        log_tool_calls: true,
        use_planner: false,
        replay_conversation: false,
        model: @model,
        tools: [AI.Tools.tool_spec!("answers_tool")],
        messages: research.messages ++ [AI.Util.system_msg(@template_prompt)]
      )
    end
  end

  # -----------------------------------------------------------------------------
  # Testing response
  # -----------------------------------------------------------------------------
  defp is_testing?(question) do
    question
    |> String.downcase()
    |> String.starts_with?("testing:")
  end

  defp get_test_response(ai, opts) do
    tools =
      AI.Tools.tools()
      |> Map.keys()
      |> Enum.map(&AI.Tools.tool_spec!(&1))

    AI.Completion.get(ai,
      log_msgs: true,
      log_tool_calls: true,
      use_planner: false,
      model: AI.Model.fast(),
      tools: tools,
      messages: [
        AI.Util.system_msg(@test_prompt),
        AI.Util.user_msg(opts.question)
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
  end

  # -----------------------------------------------------------------------------
  # Conversation management
  # -----------------------------------------------------------------------------
  defp restore_conversation(%{conversation: conversation}) do
    if Store.Project.Conversation.exists?(conversation) do
      {:ok, _ts, messages} = Store.Project.Conversation.read(conversation)
      messages
    else
      []
    end
  end

  defp save_conversation(state, %{conversation: conversation}) do
    Store.Project.Conversation.write(conversation, state.messages)
    UI.debug("Conversation saved to file", conversation.store_path)
    UI.report_step("Conversation saved", conversation.id)
    {:ok, conversation.id}
  end
end
