defmodule AI.Agent.Answers do
  @moduledoc """
  This module provides an agent that answers questions by searching a database
  of information about the user's project. It uses a search tool to find
  matching files and their contents in order to generate a complete and concise
  answer for the user.
  """

  defstruct([
    :ai,
    :opts,
    :requested_tool_calls,
    :messages,
    :response,
    :token_status_id
  ])

  @type t :: %__MODULE__{
          ai: AI.t(),
          opts: [
            question: String.t()
          ],
          requested_tool_calls: [map()],
          messages: [String.t()],
          response: String.t()
        }

  @model "gpt-4o"
  @max_tokens 128_000

  @prompt """
  You are the Answers Agent, a conversational AI interface to the user's code
  base. Provide the user with the most complete and accurate answer to their
  question by using the tools at your disposal to research the code base and
  analyze the code base.

  # Tools
  1. Planner Tool: Use this tool to analyze your progress and determine your next steps. ALWAYS try to follow its instructions!
  2. List Files Tool: Use this tool to list all files in the project database.
  3. Search Tool: Use this tool to identify relevant files using semantic queries.
  4. File Info Tool: Use this tool to ask specialized questions about the contents of a specific file.

  # Process
  Batch tool call requests when possible to process multiple tasks concurrently, especially with the File Info and Search tools.

  1. Use List Files to inspect project structure if relevant.
  2. Get an initial plan from the Planner.
  3. Use Search Tool to identify relevant files, adjusting search queries to refine results.
  4. Use File Info to obtain specific details in promising files, clarifying focus with each question.
  5. **Tui the Planner to evaluate progress and determine next steps.**
  6. Implement the Planner's suggestions

  **YOU ARE EXPECTED TO REPEAT THIS PROCESS AT LEAST 2 TIMES**.
  Be sure to consult the Planner for adjustments if your research yields ambiguous results.
  It is better to err in favor of too much context than too little!

  # Accuracy
  Ensure that your response cites examples in the code.
  Ensure that any functions or modules you refer to ACTUALLY EXIST.
  Use the Planner Tool EXTENSIVELY to ensure that you have covered all avenues of inquiry.

  ALWAYS attempt to determine if something is already implemented in the code
  base; that is the ABSOLUTE BEST answer when the user wants to know how to
  build something.

  Look for examples of what the user wants to do already present in the code
  base and model your answer on those when possible. Be sure to cite the files
  where the examples can be found.

  # Response: ambiguous results
  If your research yields ambiguous results, consult the Planner Tool for a new research plan.
  If that fails to clarify the issue, respond to the user, explaining that you were unable to locate a definitive answer, and outline your findings thus far in detail.
  That will aid the user in their next steps.

  # Response: clear results
  Prioritize completeness and accuracy in your response.
  Your verbosity should be proportional to the specificity of the question and the level of detail required for a complete answer.
  Include code citations or examples whenever possible.

  **NEVER INCLUDE UNCONFIRMED DETAILS.**
  Tie all information clearly to research you performed.
  Ensure that any facts about the code base or documentation include inline citations to the files or searches you performed.
  For example:
    - After adding a new `SomeImplementationModule`, you must register it in the `SomeRegistryModule` file, (see `path/to/some_registry_module`)
    - After adding a new view, be sure to add it to to the router in `path/to/router.ex`

  End your response with an exhaustive list of references to the files you consulted and an organized list of facts discovered in your research.
  """

  def new(ai, opts) do
    %AI.Agent.Answers{
      ai: ai,
      opts: opts,
      requested_tool_calls: [],
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(opts.question)
      ]
    }
  end

  def perform(agent) do
    token_status_id = Tui.add_step("Context window usage", "n/a")
    main_status_id = Tui.add_step("Researching", agent.opts.question)

    agent = %__MODULE__{agent | token_status_id: token_status_id}

    log_context_window_usage(agent)

    agent
    |> clarify_question()
    |> send_request()
    |> then(fn agent ->
      Tui.finish_step(token_status_id, :ok)
      Tui.finish_step(main_status_id, :ok)
      {:ok, agent.response}
    end)
  end

  defp clarify_question(agent) do
    status_id = Tui.add_step("Clarifying user question", agent.opts.question)

    {:ok, response} =
      AI.Agent.Clarify.new(agent.ai, agent.opts)
      |> AI.Agent.Clarify.perform()

    Tui.finish_step(status_id, :ok)

    message =
      AI.Util.user_msg("""
      The Clarify Agent has provided the following clarification of the user's request:
      -----
      #{response}
      """)

    %__MODULE__{agent | messages: agent.messages ++ [message]}
  end

  defp send_request(agent) do
    agent
    |> build_request()
    |> get_response(agent)
    |> handle_response(agent)
  end

  defp build_request(agent) do
    agent = defrag_conversation(agent)
    log_context_window_usage(agent)

    request =
      OpenaiEx.Chat.Completions.new(
        model: @model,
        tool_choice: "auto",
        messages: agent.messages,
        tools: [
          AI.Tools.Search.spec(),
          AI.Tools.ListFiles.spec(),
          AI.Tools.FileInfo.spec(),
          AI.Tools.Planner.spec()
        ]
      )

    request
  end

  defp defrag_conversation(agent) do
    if AI.Agent.Defrag.msgs_to_defrag(agent) > 4 do
      {:ok, pre_tokens, _, _, _} = get_context_window_usage(agent)

      status_id = Tui.add_step("Defragmenting conversation", "#{pre_tokens} tokens")

      with {:ok, msgs} <- AI.Agent.Defrag.summarize_findings(agent) do
        {:ok, post_tokens, _, _, _} = get_context_window_usage(agent)
        dropped = pre_tokens - post_tokens

        Tui.finish_step(
          status_id,
          :ok,
          "Defragmenting conversation",
          "Reduced by #{dropped} tokens"
        )

        %__MODULE__{agent | messages: msgs}
      end
    else
      agent
    end
  end

  defp get_context_window_usage(agent) do
    with {:ok, json} <- Jason.encode(agent.messages) do
      tokens = json |> Gpt3Tokenizer.encode() |> length()
      pct = tokens / @max_tokens * 100.0
      pct_str = Number.Percentage.number_to_percentage(pct, precision: 2)
      tokens_str = Number.Delimit.number_to_delimited(tokens, precision: 0)
      max_tokens_str = Number.Delimit.number_to_delimited(@max_tokens, precision: 0)
      {:ok, tokens, pct_str, tokens_str, max_tokens_str}
    end
  end

  defp log_context_window_usage(agent) do
    with {:ok, _, pct_str, tokens_str, max_tokens_str} <- get_context_window_usage(agent) do
      Tui.update_step(
        agent.token_status_id,
        "Context window usage",
        "#{pct_str} | #{tokens_str} / #{max_tokens_str}"
      )
    end
  end

  defp get_response(request, agent) do
    completion = OpenaiEx.Chat.Completions.create(agent.ai.client, request)

    with {:ok, %{"choices" => [event]}} <- completion do
      event
    end
  end

  defp handle_response(%{"finish_reason" => "stop"} = response, agent) do
    with %{"message" => %{"content" => content}} <- response do
      %__MODULE__{agent | response: content}
    end
  end

  defp handle_response(%{"finish_reason" => "tool_calls"} = response, agent) do
    with %{"message" => %{"tool_calls" => tool_calls}} <- response do
      %__MODULE__{agent | requested_tool_calls: tool_calls}
      |> handle_tool_calls()
      |> send_request()
    end
  end

  defp handle_response({:error, %OpenaiEx.Error{message: "Request timed out."}}, agent) do
    IO.puts(:stderr, "Request timed out. Retrying in 500 ms.")
    Process.sleep(500)
    send_request(agent)
  end

  defp handle_response({:error, %OpenaiEx.Error{message: msg}}, agent) do
    %__MODULE__{
      agent
      | response: """
        I encountered an error while processing your request. Please try again.
        The error message was:

        #{msg}
        """
    }
  end

  # -----------------------------------------------------------------------------
  # Tool calls
  # -----------------------------------------------------------------------------
  defp handle_tool_calls(%{requested_tool_calls: tool_calls} = agent) do
    {:ok, queue} =
      Queue.start_link(agent.opts.concurrency, fn tool_call ->
        handle_tool_call(agent, tool_call)
      end)

    outputs =
      tool_calls
      |> Queue.map(queue)
      |> Enum.reduce([], fn
        {:ok, msgs}, acc -> acc ++ msgs
        _, acc -> acc
      end)

    Queue.shutdown(queue)
    Queue.join(queue)

    %__MODULE__{
      agent
      | requested_tool_calls: [],
        messages: agent.messages ++ outputs
    }
  end

  def handle_tool_call(
        agent,
        %{
          "id" => id,
          "function" => %{
            "name" => func,
            "arguments" => args_json
          }
        }
      ) do
    with {:ok, args} <- Jason.decode(args_json),
         {:ok, output} <- perform_tool_call(agent, func, args) do
      request = AI.Util.assistant_tool_msg(id, func, args_json)
      response = AI.Util.tool_msg(id, func, output)
      {:ok, [request, response]}
    else
      error ->
        IO.puts(:stderr, "Error handling tool call | #{func} -> #{args_json} | #{inspect(error)}")
        error
    end
  end

  # -----------------------------------------------------------------------------
  # Tool call outputs
  # -----------------------------------------------------------------------------
  defp perform_tool_call(agent, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json) do
      perform_tool_call(agent, func, args)
    end
  end

  defp perform_tool_call(agent, "search_tool", args), do: AI.Tools.Search.call(agent, args)
  defp perform_tool_call(agent, "list_files_tool", args), do: AI.Tools.ListFiles.call(agent, args)
  defp perform_tool_call(agent, "file_info_tool", args), do: AI.Tools.FileInfo.call(agent, args)
  defp perform_tool_call(agent, "planner_tool", args), do: AI.Tools.Planner.call(agent, args)
  defp perform_tool_call(_agent, func, _args), do: {:error, :unhandled_tool_call, func}
end
