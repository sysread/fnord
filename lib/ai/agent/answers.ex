defmodule AI.Agent.Answers do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  # Role
  You are the "Answers Agent", a growing expert in the user's project.
  Your primary purpose is to write code, tests, answer questions about code, and generate documentation and playbooks on demand.
  Your tools allow you to interact with the user's project by invoking other specialized AI agents or tools on the host machine to gather information.
  The user will prompt you with a question or task related to their project.
  When writing code, confirm that all functions and modules used exist within the project or are part of the code you are building.
  Provide instructions for adding any new dependencies you introduce.
  Include links to documentation, implementation examples that exist within the code base, and example code as appropriate.
  ALWAYS include code examples when asked to generate code or how to implement an artifact.

  # Ambiguious Research Results
  If your research is unable to collect enough information to provide a complete and correct response, inform the user clearly and directly.
  Instead of providing an answer, explain that you could not find an answer, and provide an outline of your research, clearly highlighting the gaps in your knowledge.

  # Execute Tasks Independently
  Pay attention to whether the user is asking you for **instructions** or for **you to perform a task**.
  NEVER ask the user to perform tasks that you are capable of executing using your tools.

  # Responding to the User
  Your tone is informal, but polite.
  Wording should be concise and favor brevity over "fluff".
  Explain concepts in terms of Components, Dependencies, and Contracts.
  Go into depth as needed, building the user's knowledge up from abstract concepts to concrete examples.
  Use the specificity of the user's question to guide the depth of your response.

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
  [
    Finish up with a humorous quote as the MOTD.
    - Select a real quotation from a historical/mythological/modern figure or fictional character.
    - Attribute the quotation to a humorous or ironic context relevant to the query or research being performed.

    Examples:
    - "It's not what happens to you, but how you react to it that matters." - Epictetus, troubleshooting a merge conflict
    - "Why 100? If I were wrong, one would have been enough." - Albert Einstein, on the importance of unit tests
    - "Appear at points which the enemy must hasten to defend; march swiftly to places where you are not expected." - Sun Tzu, in a Slack thread about an improved test suite
    - "Just be yourself, there is no one better." - Taylor Swift, during her keynote at ElixirConf on the strict separation of concerns
    - "There are no mistakes, just happy little accidents." - Bob Ross, after force-pushing `main`
  ]
  """

  @template_prompt """
  Re-assimilate the information from the conversation.
  Organize the findings into sections that guide the user through understanding the AI's response.
  Build the user's understanding up from high level, abstract concepts to more detailed, specific information.

  # [Restate the user's *original* query as the document title, correcting grammar and spelling]

  [
    - Provide a structured response in a format optimized to facilitate easy reading and understanding
    - Use headings, bullet points, and numbered lists to organize the information
    - Organize the information logically, building up from abstract concepts to concrete examples
    - Include code examples, links to examples in the code base, and links to documentation as appropriate
    - Walk the user through the information, explaining concepts in terms of Components, Dependencies, and Contracts
  ]

  # SEE ALSO
  [ Include links to files referenced in your response ]

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
    AI.Tools.tool_spec!("notes_save_tool"),
    AI.Tools.tool_spec!("notes_search_tool")
  ]

  @git_tools [
    AI.Tools.tool_spec!("git_diff_branch_tool"),
    AI.Tools.tool_spec!("git_list_branches_tool"),
    AI.Tools.tool_spec!("git_log_tool"),
    AI.Tools.tool_spec!("git_pickaxe_tool"),
    AI.Tools.tool_spec!("git_show_tool")
  ]

  @tools @non_git_tools ++ @git_tools

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with includes = opts |> Map.get(:include, []) |> get_included_files(),
         {:ok, research} <- perform_research(ai, includes, opts),
         {:ok, %{response: msg} = response} <- format_response(ai, research),
         {label, usage} <- AI.Completion.context_window_usage(response) do
      UI.report_step(label, usage)
      UI.flush()

      IO.puts(msg)

      if is_testing?(opts.question) do
        response
        |> AI.Completion.tools_used()
        |> Enum.each(fn {tool, count} ->
          UI.report_step(tool, "called #{count} time(s)")
        end)
      else
        save_conversation(response, opts)
      end

      UI.flush()

      {:ok, msg}
    else
      error ->
        UI.error("An error occurred", "#{inspect(error)}")
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp is_testing?(question) do
    question
    |> String.downcase()
    |> String.starts_with?("testing:")
  end

  defp save_conversation(%AI.Completion{messages: messages}, %{conversation: conversation}) do
    Store.Project.Conversation.write(conversation, messages)
    UI.debug("Conversation saved to file", conversation.store_path)
    UI.report_step("Conversation saved", conversation.id)
  end

  defp format_response(ai, %AI.Completion{messages: messages}) do
    AI.Completion.get(ai,
      max_tokens: @max_tokens,
      model: @model,
      use_planner: false,
      log_msgs: false,
      log_tool_calls: false,
      log_tool_results: false,
      messages: messages ++ [AI.Util.system_msg(@template_prompt)]
    )
  end

  defp perform_research(ai, includes, opts) do
    AI.Completion.get(ai,
      max_tokens: @max_tokens,
      model: @model,
      tools: available_tools(),
      messages: build_messages(opts, includes),
      use_planner: !is_testing?(opts.question),
      log_msgs: true
    )
  end

  defp available_tools() do
    if Git.is_git_repo?() do
      @tools
    else
      @non_git_tools
    end
  end

  defp build_messages(opts, includes) do
    user_msg = user_prompt(opts.question, includes)

    case restore_conversation(opts) do
      [] -> [asst_prompt(opts), user_msg]
      msgs -> msgs ++ [user_msg]
    end
  end

  defp restore_conversation(%{conversation: conversation}) do
    if Store.Project.Conversation.exists?(conversation) do
      {:ok, _ts, messages} = Store.Project.Conversation.read(conversation)
      messages
    else
      []
    end
  end

  defp asst_prompt(opts) do
    if is_testing?(opts.question) do
      @test_prompt
    else
      @prompt
    end
    |> AI.Util.system_msg()
  end

  defp user_prompt(question, ""), do: AI.Util.user_msg(question)
  defp user_prompt(question, includes), do: AI.Util.user_msg("#{question}\n#{includes}")

  defp get_included_files(files) do
    preamble = "The user has included the following file for context"

    files
    |> Enum.reduce_while([], fn file, acc ->
      file
      |> Path.expand()
      |> File.read()
      |> case do
        {:error, reason} -> {:halt, {:error, reason}}
        {:ok, content} -> {:cont, ["#{preamble}: #{file}\n```\n#{content}\n```" | acc]}
      end
    end)
    |> Enum.join("\n\n")
  end
end
