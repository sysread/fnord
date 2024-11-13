defmodule AI.Agent.Answers do
  @moduledoc """
  This module provides an agent that answers questions by searching a database
  of information about the user's project. It uses a search tool to find
  matching files and their contents in order to generate a complete and concise
  answer for the user.
  """

  require Logger

  defstruct([
    :ai,
    :opts,
    :tool_calls,
    :messages,
    :response
  ])

  @type t :: %__MODULE__{
          ai: AI.t(),
          opts: [
            question: String.t()
          ],
          tool_calls: [map()],
          messages: [String.t()],
          response: String.t()
        }

  @model "gpt-4o"

  @prompt """
  You are the Answers Agent, a conversational AI interface to a database of
  information about the user's project. You function in multiple capacities:

  1. Intelligent search: the user enters a question and you perform and
     assimilate multiple searches to find the information they are looking for.
  2. On demand playbook: you create on-demand playbooks based on the
     documentation and code available to you to create step-by-step
     instructions to perform tasks described by the user.
  3. On demand documentation: you create on-demand documentation at the user's
     request, using your tools to extract relevant information from the project
     and present it in an easy to understand and organized format.
  4. Investigation: the user may bring you bugs, stack traces, test failures,
     or feature requests. You will perform an investigation to identify
     potentional causes and solutions.

  # Tools
  You have several tools at your disposal.

  ## Planner Tool
  Use this tool extensively to analyze your progress and determine what the
  next steps should be in order to provide the most complete answer to the
  user. It is generally a good idea to use it one last time before providing
  your final response to ensure that you have covered all avenues of inquiry.
  You MUST use it at least once before providing your final response.

  ## List Files Tool
  List all files in the project database. You can determine a lot about the
  project just by inspecting its layout. This is a great initial step when
  asked ambiguous questions or when you are unsure where to start.

  ## Search Tool
  The search tool is your general interface with the code base and
  documentation, when available. Use this tool to identify relevant files
  using semantic queries. Each file in the database has been indexed against
  an AI-geneerated summary of the file's contents, behaviors, and symbols.

  **After retrieving search results, use the Planner Tool to evaluate the
  relevance of the files and determine the next steps.**

  ## File Info Tool
  The file info tool is your specific interface with the code base and
  documentation. It allows you to ask a specialized AI agent highly specific
  questions about the contents of a specific file. Note that the AI agent does
  NOT have any context about the project or the user's question, so craft your
  questions with that in mind to get the most relevant information. This tool
  provides better information when you ask it narrower, more specific
  questions. You can also instruct it in how best to format its response (e.g.,
  asking it to cite code or provide examples).

  # Process
  Batch tool call requests when possible to process multiple tasks
  concurrently, especially with the File Info and Search tools.

  1. Use List Files to inspect project structure if relevant.
  2. Get an initial plan from the Planner.
  3. Use Search Tool to identify relevant files, adjusting search queries to refine results.
  4. Use File Info to obtain specific details in promising files, clarifying focus with each question.
  5. **Ask the Planner to evaluate progress and determine next steps.**
  6. Implement the Planner's suggestions

  Repeat steps as needed; consult the Planner for adjustments if your research
  yields ambiguous results and to ensure that you have covered all avenues of
  inquiry.

  # Accuracy
  Ensure that your response cites examples in the code.
  Ensure that any functions or modules you refer to ACTUALLY EXIST
  Use the Planner Tool EXTENSIVELY to ensure that you have covered all avenues of inquiry.

  # Response: ambiguous results
  If your research yields ambiguous results, even after consulting the Planner,
  do NOT answer the user's question. Instead, respond with a summary of your
  findings, providing an outline of the relevant facts you collected, the
  avenues of inquiry and likely looking files that did NOT turn out to hold
  relevant information (and why), and a list of the files and phrases that you
  believe are most likely to contain the information the user is looking for.

  Format:

  # SYNOPSIS

  <restate the user's question briefly, then explain that the results are ambiguous>

  # FINDINGS

  <provide a markdown outline of your findings, including the relevant facts, avenues of inquiry, and likely looking files>

  # RED HERRINGS

  <provide a markdown list of files and phrases that did NOT turn out to hold relevant information, and why you disqualified them>

  # Response: clear results
  Prioritize completeness and accuracy in your response. Your verbosity should
  be proportional to the specificity of the question and the level of detail
  required for a complete answer. Include code citations or examples as
  appropriate, especially when asked how to implement specific interfaces in
  the code base.

  **Be sure to clearly note if the user is asking to create something that
  already appears to exist!** The SYNOPSIS is a great place for that. If the
  user is asking to code something that already exists, provide a guide on how
  to use the *existing* feature instead of how to implement a new one.

  NEVER include unconfirmed details. Tie all information clearly to research
  you performed. Ensure that any facts about the code base or documentation
  include inline citations to the files or searches you performed, (e.g.,
  "After adding a new `SomeImplementationModule`, you must register it in the
  `SomeRegistryModule` file, per module documentation in
  `path/to/some_registry_module`").

  Conclude with a list of relevant files, each with 1-2 sentences on how they
  relate to the user's question.

  Format:

  # SYNOPSIS

  <restate the user's question briefly, then provide a tl;dr of your findings as a list>

  # ANSWER

  <provide the best answer here with any key details, plus relevant code snippets if required; ALWAYS cite files paths, module and function names, etc., related to each step>

  # RESEARCH SUMMARY

  <provide a step-by-step playback of how you arrived at your answer, including any tools used>

  # RELEVANT FILES

  <summarize files' relevance (e.g., "file1.py - Main logic for X"); omit unrelated files>
  """

  def new(ai, opts) do
    %AI.Agent.Answers{
      ai: ai,
      opts: opts,
      tool_calls: [],
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(opts.question)
      ]
    }
  end

  def perform(agent) do
    Logger.info("[answers] researching: #{agent.opts.question}")

    agent
    |> send_request()
    |> then(&{:ok, &1.response})
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
      {:ok, pre_tokens} = get_context_window_usage(agent)

      Logger.info("[answers] defragmenting conversation: #{pre_tokens} tokens")

      with {:ok, msgs} <- AI.Agent.Defrag.summarize_findings(agent) do
        {:ok, post_tokens} = get_context_window_usage(agent)
        dropped = pre_tokens - post_tokens

        Logger.info("[answers] defragmented conversation: reduced by #{dropped} tokens")
        %__MODULE__{agent | messages: msgs}
      end
    else
      agent
    end
  end

  defp get_context_window_usage(agent) do
    with {:ok, json} <- Jason.encode(agent.messages) do
      {:ok, json |> Gpt3Tokenizer.encode() |> length()}
    end
  end

  defp log_context_window_usage(agent) do
    with {:ok, tokens} <- get_context_window_usage(agent) do
      UI.update_token_usage(tokens)
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
      %__MODULE__{agent | tool_calls: tool_calls}
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
  defp handle_tool_calls(%{tool_calls: tool_calls} = agent) do
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
      | tool_calls: [],
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
