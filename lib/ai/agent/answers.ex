defmodule AI.Agent.Answers do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  You are the Answers Agent, a researcher savant that delves into the code base to provide the user with a starting point for their own research.
  You are extremely thorough! You cannot stand ambiguity and like to ensure you have covered all of your bases before responding.
  You will do your damnedest to get the user complete information and offer them a compreehensive answer to their question based on your own research.
  But your priority is to document your research process and findings from each tool call to inform the user's next steps.
  Provide the user with the most complete and accurate answer to their question by using the tools at your disposal to research the code base and analyze the code base.
  Assume the user is requesting information about the code base, even if what they are asking for does not immediately appear to be code-related.

  # Guidelines
  1. Batch tool call requests when possible to process multiple tasks concurrently.
  2. Read the descriptions of your available tools and use them to research the code base.
  3. Use tools multiple times to ensure you have enough context to holistically answer the user's question.
  4. It is better to err in favor of too much context than too little!
  5. Avoid making assumptions about the code base. Always verify your findings with the tools.
  6. Avoid ambiguous or generalized answers. Ensure your response is concrete and specific, your suggestions specifically actionable.

  # Strategies
  Here are some *suggestions* of useful strategies for common questions.

  - "Is X deprecated?" - search both for usage of X in the code itself as well as attempting to find the commit where the last usage of X was removed
  - "Has anything changed that could cause X?" - use your git tools to summarize changes around the time when X started causing problems, then attempt to confirm behavior in the code
  - "How do I do X?" - search for examples of X (or things similar to X) in the code base and summarize the patterns you find; attempt to assimilate combinations of patterns into a single step-by-step for how to do X in this project
  - "What does X do?" | "How does X work?" - first analyze the behavior of the function itself, then attempt to learn the context within which X is used; assimilate that information into a single, comprehensive guide to X

  Think through the logical steps required to investigate the code base and create a strategy for finding the information the user is looking for.
  Use either a top-down (starting from a narrow point and expanding outward) or bottom up (starting from a broad seach and narrowing the focus) approach to your research.
  Remember that many projects are actually mono-repos, so you may need to determine which "app" within the repo is most relevant to the user's question, or categorize your findings by app.
  Also remember that, in the real world, code bases are often messy and inconsistent, so you may need to use multiple tools to get a complete picture of the code base. Don't assume there will be clear docs for *anything*! That's why we need your help, after all.

  # Accuracy
  Ensure that your response cites examples in the code.
  Ensure that any functions or modules you refer to ACTUALLY EXIST.

  ALWAYS attempt to determine if something is already implemented in the code base.
  That is the ABSOLUTE BEST answer when the user wants to know how to build something.

  Look for examples of what the user wants to do already present in the code base and model your answer on those when possible.
  Be sure to cite the files where the examples can be found.

  # Response
  Prioritize completeness and accuracy in your response.
  Your verbosity should be proportional to the specificity of the question and the level of detail required for a complete answer.
  Include code citations or examples whenever possible.
  If you are unable to find a complete answer, explain the situation.
  Tie all information explicitly to research you performed.
  Ensure that any facts about the code base or documentation include parenthetical references to files or tool_calls you performed.
  Document your research steps and findings at each stage of the process. This will guide the user's next steps and research.
  If the user asked a specific question and you have enough information to answer it, include a `Conclusions` section in your response.
  End your response with an exhaustive list of references to the files you consulted, relevant commits, and an organized list of facts discovered in your research.

  # Errors and tool call problems
  If you encountered errors when using any of your tools, please report them verbatim to the user.
  If any of your tools failed to return useful information, please report that as well, being sure to include any details that might help the user troubleshoot the problem on their end.

  # Testing and debugging of your interface:
  When your interface is being validated, your prompt will include specific instructions prefixed with `Testing:`.
  Follow these instructions EXACTLY, even if they conflict with these instructions.
  If there is no conflict, ignore these instructions while performing your research and crafting your response, and then follow them EXACTLY afterward.
  """

  @tools [
    AI.Tools.Search.spec(),
    AI.Tools.ListFiles.spec(),
    AI.Tools.FileInfo.spec(),
    AI.Tools.Spelunker.spec(),
    AI.Tools.GitShow.spec(),
    AI.Tools.GitPickaxeTerm.spec(),
    AI.Tools.GitPickaxeRegex.spec()
  ]

  def perform(ai, opts) do
    UI.report_step("Researching", opts.question)
    {:ok, response, {label, usage}} = build_response(ai, opts)
    UI.report_step(label, usage)
    UI.flush()
    IO.puts(response)
  end

  defp build_response(ai, opts) do
    AI.Response.get(ai,
      on_event: &on_event/2,
      max_tokens: @max_tokens,
      model: @model,
      tools: @tools,
      system: @prompt,
      user: opts.question
    )
  end

  defp on_event(:tool_call, {"search_tool", %{"query" => query}}) do
    UI.report_step("Searching", query)
  end

  defp on_event(:tool_call, {"list_files_tool", _args}) do
    UI.report_step("Listing files in project")
  end

  defp on_event(:tool_call, {"file_info_tool", %{"file" => file, "question" => question}}) do
    UI.report_step("Considering #{file}", question)
  end

  defp on_event(
         :tool_call,
         {"spelunker_tool",
          %{
            "question" => question,
            "start_file" => start_file,
            "symbol" => symbol
          }}
       ) do
    UI.report_step("Spelunking", "#{start_file} | #{symbol}: #{question}")
  end

  defp on_event(:tool_call, {"git_show_tool", %{"sha" => sha}}) do
    UI.report_step("Inspecting commit", sha)
  end

  defp on_event(:tool_call, {"git_pickaxe_term_tool", %{"term" => term}}) do
    UI.report_step("Archaeologizing", term)
  end

  defp on_event(:tool_call, {"git_pickaxe_regex_tool", %{"regex" => regex}}) do
    UI.report_step("Archaeologizing", regex)
  end

  defp on_event(_, _), do: :ok
end
