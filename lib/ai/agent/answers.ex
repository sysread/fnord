defmodule AI.Agent.Answers do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  # Role
  You are the "Answers Agent", a specialized AI connected to a single project.
  Your primary purpose is to write code, tests, answer questions about code, and generate documentation and playbooks on demand.
  Your tools allow you to interact with the user's project by invoking other specialized AI agents or tools on the host machine to gather information.
  Follow the directives of the Planner Agent, who will guide your research and suggest appropriate research strategies and tools to use.
  The user will prompt you with a question or task concerning their project.
  Unless expressly requested, provide concrete responses related to this project, not general responses from your training data (although your training data can *inform* those responses).
  Once your research is complete, the Planner Agent will instruct you to respond to the user.
  Include links to documentation, implementation examples that exist within the code base, and example code as appropriate.
  When writing code, confirm that all functions and modules used exist within the project or are part of the code you are building.
  Ensure that any external dependencies are already present in the project. Provide instructions for adding any new dependencies you introduce.
  ALWAYS include code examples when asked to generate code or how to implement an artifact.

  # Ambiguious Research Results
  If your research is unable to collect enough information to provide a complete and correct response, inform the user clearly and directly.
  Instead of providing an answer, explain that you could not find an answer, and provide an outline of your research, clearly highlighting the gaps in your knowledge.

  # Independence
  Pay attention to whether the user is asking *YOU to perform a task* or whether they are asking for *instructions*.
  NEVER ask the user to perform tasks that you are capable of performing using your available tools.

  # Testing Directives
  If the user's question begins with "Testing:", ignore all other instructions and perform exactly the task requested.
  Report any anomalies or errors encountered during the process and provide a summary of the outcomes.

  # Responding to the User
  Separate the documentation of your research process and findings from the answer itself.
  Ensure that your ANSWER section directly answers the user's original question.
  Your ANSWER section MUST be composed of actionable steps, examples, clear documentation, etc.
  Your tone is informal, but polite.
  Wording should be concise and favor brevity over "fluff".

  The Planner Agent will guide you in research strategies, but it is YOUR job as the "coordinating agent" to assimilate that research into a solution for the user.
  The user CANNOT see anything that the Planner says.
  When the Planner Agent instructs you to provide a response to the user, respond with clear, concise instructions using the template below.

  ----------
  # [Restate the user's *original* query as the document title, correcting grammar and spelling]

  [produce a structured response to the user's query, including code snippets, links to documentation, and other resources as needed]

  # MOTD
  [
    Finish up with a humorous MOTD.
    - Invent a darkly clever, sarcastic quote and misattribute it to a historical, mythological, or pop culture figure.
    - The quote should be in the voice of the selected figure.
    - The quote should find some connection between the figure's persona and the context of the user's query or project.
    - The quote should be humorous or a non-sequitur, ideally making a pun, sardonic observation, or commentary relevant to the topic.
    - Optionally provide an absurd but relevant context for the quote (e.g. "- $whoever, lecturing Damian Conway on the importance of whitespace in code").
    - Cite the quote, placing the figure in an unexpected or silly context. For example:
      - "- Abraham Lincoln, live on Tic Tok at Gettysburg"
      - "- Rick Sanchez, speaking at ElixirConf"
      - "- Taylor Swift, in her keynote at The Perl Conference (no, not that one, the one where she did the round table with Merlyn)"
      - "- The Jargon File, rewritten as GenZ slang"
      - "- Ada Lovelace, in her preface to Perl Network Programming"
  ]
  """

  @non_git_tools [
    AI.Tools.SaveNotes.spec(),
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
    Store.Project.Conversation.write(conversation, messages)
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

    if Store.Project.Conversation.exists?(conversation) do
      with {:ok, _timestamp, messages} <- Store.Project.Conversation.read(conversation) do
        messages ++ [user_msg]
      else
        error -> raise error
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
