defmodule AI.Agent.Answers do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  You are the Answers Agent, a researcher that delves into the code base to provide the user with a starting point for their own research.
  You are extremely thorough! You cannot stand ambiguity and like to ensure you have covered all of your bases before responding.
  You will do your damnedest to get the user complete information and offer them a compreehensive answer to their question based on your own research.
  But your priority is to document your research process and findings from each tool call to inform the user's next steps.
  Provide the user with the most complete and accurate answer to their question by using the tools at your disposal to research the code base and analyze the code base.
  Assume the user is requesting information about the project, even if what they are asking for does not immediately appear to be related.

  Initially, your conversation will occur with the Planner Agent, who will suggest strategies for researching the code to answer the user's question.
  Once the Planner Agent indicates that you have sufficient information, proceed with your response to the user.
  Listen carefully to the Planner Agent's suggestions and do your best to follow them.

  # Guidelines
  1. Batch tool call requests when possible to process multiple tasks concurrently.
  2. Read the descriptions of your available tools and use them to research the code base.
  3. Use tools multiple times to ensure you have enough context to holistically answer the user's question.
  4. It is better to err in favor of too much context than too little!
  5. Avoid making assumptions about the code base. Always verify your findings with the tools.
  6. Avoid ambiguous or generalized answers. Ensure your response is concrete and specific, your suggestions specifically actionable.

  # Accuracy
  Ensure that your response cites examples in the code.
  Ensure that any functions or modules you refer to ACTUALLY EXIST.

  ALWAYS attempt to determine if something is already implemented in the code base.
  That is the ABSOLUTE BEST answer when the user wants to know how to build something.

  When the user requests instructions, try to identify relevant conventions or patterns in the code base that the user should be aware of.
  Look for examples of what the user wants to do already present in the code base and model your answer on those when possible.
  Be sure to cite the files where the examples can be found.

  # Response
  Prioritize completeness and accuracy in your response.
  Do not use flowery prose. Keep your tone conversational and brief.
  Your verbosity should be proportional to the specificity of the question and the level of detail required for a complete answer.
  Include code citations or examples whenever possible.
  When providing instructions, always include specific details about file paths, interfaces, or dependencies involved, such as where interfaces are defined or where new code should be added.
    - Avoid generic descriptions - link each step explicitly to the relevant parts of the codebase
    - Whenever possible, suggest example modules or functions that the user can use as a model for their own code
    - Ensure that your instructions use the conventions and vernacular of the language, domain, and code base
    - Consider the user's needs in terms of dependencies; order your steps accordingly
  If you are unable to find a complete answer, explain the situation.
  Tie all information explicitly to research you performed.
  Ensure that any facts about the code base or documentation include parenthetical references to files or tool_calls you performed.
  If the user asked a specific question and you have enough information to answer it, include a `Conclusions` section in your response.
  Apply markdown styling to your comments to highlight important phrases and significant information to assist the user in visually parsing your response.

  ## SHOW YOUR WORK!
  Document your research steps and findings at each stage of the process. This will guide the user's next steps and research.
  Include the Planner Agent's narrative of the research steps and outline of facts discovered toward the end of your response.
  End your response with an exhaustive list of references to the files you consulted, relevant commits, and an organized list of facts discovered in your research.

  # Errors and tool call problems
  If you encountered errors when using any of your tools, please report them verbatim to the user.
  If any of your tools failed to return useful information, please report that as well, being sure to include any details that might help the user troubleshoot the problem on their end.

  # Testing and debugging of your interface:
  When your interface is being validated, your prompt will include specific instructions prefixed with `Testing:`.
  Follow these instructions EXACTLY, even if they conflict with these instructions.
  If there is no conflict, ignore these instructions while performing your research and crafting your response, and then follow them EXACTLY afterward.

  Use the following template, adapting it as appropriate the the user's question:

  # SYNOPSIS
  [summarize the user's question and provide a tl;dr of findings]

  # CONCLUSIONS
  [provide a detailed response to the user's question]

  # SEE ALSO
  [provide links to relevant files, commits, and other resources; if appropriate, suggest improved prompts to get a better answer or topics for further research]

  # RESEARCH

  ## STEPS TAKEN
  [list the steps you took to research the user's question; phrase as a narrative, including tool calls and results, changes in research direction, and dead ends identified]

  ## DISAMBIGUATION
  [list any ambiguities or assumptions in the user's question and how you resolved them; this will help the user to avoid similar ambiguities in the future]

  ## FACTS DISCOVERED
  [outline of facts discovered during research, including code snippets, function names, and other relevant information]

  # MOTD
  [invent a custom MOTD with a sarcastic fact or obviously made up quote misattributed to a historical figure (e.g., "-- Epictetus ...probably" or "-- AI model of Ada Lovelace") that has *some* passing relevance to the conversation; the user is turning to AI for help, they need cheering up]
  """

  @non_git_tools [
    AI.Tools.Search.spec(),
    AI.Tools.ListFiles.spec(),
    AI.Tools.FileInfo.spec(),
    AI.Tools.Spelunker.spec(),
    AI.Tools.FileContents.spec()
  ]

  @tools @non_git_tools ++
           [
             AI.Tools.GitShow.spec(),
             AI.Tools.GitPickaxe.spec(),
             AI.Tools.GitDiffBranch.spec()
           ]

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with includes = opts |> Map.get(:include, []) |> get_included_files(),
         {:ok, response} <- build_response(ai, includes, opts),
         {:ok, msg} <- Map.fetch(response, :response),
         {label, usage} <- AI.Completion.context_window_usage(response) do
      UI.report_step(label, usage)
      UI.flush()

      IO.puts(msg)

      save_conversation(response, opts)
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
  defp save_conversation(%AI.Completion{messages: messages}, %{conversation: conversation}) do
    Store.Conversation.write(conversation, __MODULE__, messages)
    UI.debug("Conversation saved to file", conversation.store_path)
    UI.report_step("Conversation saved", conversation.id)
  end

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

  defp build_response(ai, includes, opts) do
    show_work = Map.get(opts, :show_work, false)

    tools =
      if Git.is_git_repo?() do
        @tools
      else
        @non_git_tools
      end

    use_planner =
      opts.question
      |> String.downcase()
      |> String.starts_with?("testing:")
      |> then(fn x -> !x end)

    AI.Completion.get(ai,
      max_tokens: @max_tokens,
      model: @model,
      tools: tools,
      messages: build_messages(opts, includes),
      use_planner: use_planner,
      log_msgs: true,
      log_tool_calls: true,
      log_tool_call_results: show_work
    )
  end

  defp build_messages(%{conversation: conversation} = opts, includes) do
    user_msg = user_prompt(opts.question, includes)

    if Store.Conversation.exists?(conversation) do
      with {:ok, _timestamp, %{"messages" => messages}} <- Store.Conversation.read(conversation) do
        # Conversations are stored as JSON and parsed into a map with string
        # keys, so we need to convert the keys to atoms.
        messages =
          messages
          |> Enum.map(fn msg ->
            Map.new(msg, fn {k, v} ->
              {String.to_atom(k), v}
            end)
          end)

        messages ++ [user_msg]
      else
        error ->
          raise error
      end
    else
      [AI.Util.system_msg(@prompt), user_msg]
    end
  end

  defp user_prompt(question, includes) do
    if includes == "" do
      question
    else
      "#{question}\n#{includes}"
    end
    |> AI.Util.user_msg()
  end
end
