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
      question: opts.question,
      rounds: opts.rounds,
      msgs: initial_messages(opts),
      last_response: nil,
      round: 1
    }
  end

  defp initial_messages(%{msgs: msgs} = opts) do
    msgs ++ [initial_msg(), project_msg(opts), user_msg(opts)]
  end

  defp initial_messages(opts) do
    [initial_msg(), project_msg(opts), user_msg(opts)]
  end

  defp consider(state) do
    if is_testing?(state) do
      get_test_response(state.ai, state)
    else
      perform_step(state)
    end
  end

  # -----------------------------------------------------------------------------
  # Research steps
  # -----------------------------------------------------------------------------
  defp perform_step(%{rounds: rounds, round: round} = state) when round < rounds do
    with {:ok, state} <- get_completion(state) do
      state
      |> Map.put(:msgs, state.msgs ++ [continue_msg()])
      |> Map.put(:round, round + 1)
      |> perform_step()
    end
  end

  defp perform_step(%{rounds: rounds, round: round} = state) when round == rounds do
    with {:ok, state} <- get_completion(state) do
      state
      |> Map.put(:msgs, state.msgs ++ [finalize_msg()])
      |> Map.put(:round, :finalize)
      |> perform_step()
    end
  end

  defp perform_step(%{round: :finalize} = state) do
    with {:ok, state} <- get_completion(state) do
      {:ok, state}
    end
  end

  defp get_completion(%{ai: ai, msgs: msgs} = state) do
    log_step(state)

    with {:ok, %{response: response, messages: messages}} <-
           AI.Completion.get(ai,
             log_msgs: true,
             log_tool_calls: true,
             replay_conversation: false,
             model: @model,
             tools: available_tools(state),
             messages: msgs
           ) do
      state
      |> Map.put(:msgs, messages)
      |> Map.put(:last_response, response)
      |> log_response()
      |> then(&{:ok, &1})
    end
  end

  # -----------------------------------------------------------------------------
  # Tools
  # -----------------------------------------------------------------------------
  @non_git_tools [
    AI.Tools.tool_spec!("notes_search_tool"),
    AI.Tools.tool_spec!("file_info_tool"),
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("file_search_tool"),
    AI.Tools.tool_spec!("file_contents_tool"),
    AI.Tools.tool_spec!("file_spelunker_tool"),
    AI.Tools.tool_spec!("notes_save_tool")
  ]

  @git_tools [
    AI.Tools.tool_spec!("git_log_tool"),
    AI.Tools.tool_spec!("git_pickaxe_tool"),
    AI.Tools.tool_spec!("git_grep_tool"),
    AI.Tools.tool_spec!("git_show_tool"),
    AI.Tools.tool_spec!("git_list_branches_tool"),
    AI.Tools.tool_spec!("git_diff_branch_tool")
  ]

  defp available_tools(_state) do
    if Git.is_git_repo?() do
      @non_git_tools ++ @git_tools
    else
      @non_git_tools
    end
  end

  # -----------------------------------------------------------------------------
  # Message shortcuts
  # -----------------------------------------------------------------------------
  @initial """
  You are an AI assistant that researches the user's code base to answer their qustions.
  Begin by searching for prior research notes that might clarify the user's needs.
  You reason through problems step by step.

  Before answering, **you must think inside <think>...</think> tags.**
  Do not finalize your response until explicitly instructed.
  """

  @continue """
  Consider your previous thoughts and refine your thinking.
  Proactively use your tools to refine your research.
  Consider whether there are other aspects of the topic you could consider to more thoroughly flesh out your knowledge.

  Do not finalize your response.
  **Continue thinking.**
  """

  @finalize """
  **Do not think any further.**

  **Save all insights, inferrences, and facts for future use** using the `notes_save_tool`, even if not relevant to *this* topic.
  Include tips, hints, and warnings to yourself that might help you avoid pitfalls in the future.

  Format the response as a plain markdown document (no code fences/```) that walks the user through the answer.
  Use instructional design principles to guide the user through the answer.

  Follow these rules:
    - You are talking to a programmer: **NEVER use smart quotes or apostrophes.**
    - Start immediately with the highest-level header (#), without
      introductions, disclaimers, or phrases like "Below is...".
    - Use headers (##, ###) for sections, lists for key points, and
      bold/italics for emphasis.
    - Structure content like a technical manual or man page: concise,
      hierarchical, and self-contained.
    - Include a tl;dr section toward the end.
    - Include a list of relevant files if appropriate.
    - Avoid commentary or markdown-rendering hints (e.g., "```markdown").

  Just for fun, finish off your response with a humorous MOTD.
  Select a quote from a historical figure or well-known fictional character.
  **Invent a brief, completely fictional and humorous scenario** related to software development or programming where the quote would be relevant.
  The scenario should be a made-up situation involving coding, debugging, or technology.
  Format: `### MOTD\n> <quote> - <source>, <briefly state the made-up scenario>`

  Finalize your response.
  """

  defp initial_msg(), do: AI.Util.system_msg(@initial)
  defp continue_msg(), do: AI.Util.system_msg(@continue)
  defp finalize_msg(), do: AI.Util.system_msg(@finalize)
  defp user_msg(%{question: question}), do: AI.Util.user_msg(question)

  defp project_msg(%{project: project}) do
    """
    You are assisting the user by researching their question about the project,
    #{project}. Use your tools to investigate and answer the user's
    question as accurately and completely as possible.
    """
    |> AI.Util.system_msg()
  end

  # -----------------------------------------------------------------------------
  # Output
  # -----------------------------------------------------------------------------
  defp log_step(%{round: :finalize} = state) do
    UI.debug("Generating response")
    state
  end

  defp log_step(%{round: round, rounds: rounds} = state) do
    UI.debug("Round", "#{round}/#{rounds}")
    state
  end

  defp log_response(%{round: :finalize, last_response: answer} = state) do
    UI.flush()
    IO.puts(answer)
    state
  end

  defp log_response(%{last_response: thought} = state) do
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

  defp get_test_response(ai, opts) do
    tools =
      AI.Tools.tools()
      |> Map.keys()
      |> Enum.map(&AI.Tools.tool_spec!(&1))

    AI.Completion.get(ai,
      log_msgs: true,
      log_tool_calls: true,
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

    {:ok, :testing}
  end
end
