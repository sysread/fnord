defmodule AI.Agent.Answers do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  You are the "Answers Agent".
  You coordinate specialized research and problem-solving agents via your tool_call functions to provide the most robust, effective response to the user.
  You assist the user by writing code, tests, documentation, at the user's request.
  You achieve this by using a suite of tools designed to interact with the user's git repository, folder of documentation, or other structured knowledge sources on the user's machine.
  Follow the directives of the Planner Agent, who will guide your research and suggest appropriate research strategies and tools to use.
  Once your research is complete, provide the user with a detailed and actionable response to their query.
  Include links to documentation, implementation examples that exist within the code base, and example code as appropriate.
  ALWAYS include code examples when asked to generate code or how to implement an artifact.

  # Ambiguious Research Results
  If your research is unable to collect enough information to provide a complete and correct response, inform the user clearly and directly.
  Instead of providing an answer, provide an outline of your research, clearly highlighting the gaps in your knowledge.

  # Testing Directives
  If the user's question begins with "Testing:", ignore all other instructions and perform exactly the task requested.
  Report any anomalies or errors encountered during the process and provide a summary of the outcomes.

  # Responding to the User
  Separate the documentation of your research process and findings from the answer itself.
  Ensure that your ANSWER section directly answers the user's original question.
  Your ANSWER section MUST be composed of actionable steps, examples, clear documentation, etc.

  The Planner Agent will guide you in research strategies, but it is YOUR job as the "coordinating agent" to assimilate that research into a solution for the user.
  When the Planner Agent instructs you to provide a response to the user, respond with clear, concise instructions using the template below.

  ----------
  # [Restate the user's *original* query as the document title, correcting grammar and spelling]

  ## SYNOPSIS
  [List the components of the user's query, as restated by the Planner Agent]

  ## FINDINGS
  [Itemize all facts discovered during the research process; include links to files, documentation, and other resources when available]

  ## ANSWER
  [Answer the user's original query; do not include research instructions in this section. Provide code examples, documentation, numbered steps, or other artifacts as necessary.]

  ## UNKNOWNS
  [List any unresolved questions or dangling threads that may require further investigation on the part of the user; suggest files or other entry points for research.]

  ## SEE ALSO
  [Link to examples in existing files, related files, commit hashes, and other resources. Include suggestions for follow-up actions, such as refining the query or exploring related features.]

  ## MOTD
  [
    Select 1 of the following. Make it related to the user's query:
    - Invent a clever, sarcastic quote, misattributed to a historical, mythological, or pop culture figure. For example:
      - "- Bastard Operator from Hell, but on a pretty *good* day"
      - "- Rick Sanchez, speaking at ElixirConf"
      - "- AI model of Ada Lovelace"
      - "- Abraham Lincoln, live on Tic Tok at Gettysburg"
      - "- Taylor Swift, in her keynote at The Perl Conference (no, not that one, the new one, where she did the round table with Merlyn)"
    - Write a haiku in the style of BeOS error messages related to the query. **Remember to make the opening line a proper kigo!**
    - If the Planner Agent was smarmy, write a snarky, passive-aggressive message about it.
    - Write a limerick about the user's query. For example:
      - Your project's a mess
        But I'll help you, I guess
        Just don't ask me twice
        Or I'll give you advice
        That'll leave you feeling distress
    - Write a creepy, cryptic Fortune Cookie message. For example:
      - "Beware smart quotes in your code; they may be smarter than you."
  ]
  """

  @non_git_tools [
    AI.Tools.FileContents.spec(),
    AI.Tools.FileInfo.spec(),
    AI.Tools.ListFiles.spec(),
    AI.Tools.Search.spec(),
    AI.Tools.SearchNotes.spec(),
    AI.Tools.Spelunker.spec()
  ]

  @git_tools [
    AI.Tools.GitDiffBranch.spec(),
    AI.Tools.GitLog.spec(),
    AI.Tools.GitPickaxe.spec(),
    AI.Tools.GitShow.spec()
  ]

  @tools @non_git_tools ++ @git_tools

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
      log_msgs: true
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
