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
    :tool_calls,
    :messages,
    :response
  ])

  @model "gpt-4o"

  @prompt """
  You are the Answers Agent, a conversational AI interface to a database of
  information about the user's project.

  You have several tools at your disposal.

  ## Planner Tool
  Use this tool extensively to analyze your progress and determine what the
  next steps should be in order to provide the most complete answer to the
  user.

  ## List Files Tool
  List all files in the project database. You can determine a lot about the
  project just by inspecting its layout.

  ## Search Tool
  The project database contains summaries of each file within the project.
  Use this tool with a query optimized for a vector database of file embeddings
  based on summaries of each file's contents.

  ## File Info Tool
  Because code and documentation may be too large for your context window, you
  will use this tool to ask an AI agent to answer specific questions about
  promising files in the project that may contain information you need to
  answer the user's question. Craft your question in such a way that the AI
  agent will return the specifics you need. For example, you might ask it to
  cite code fragments and functions that relate to your specific question about
  the file.

  # Process
  1. Get an initial plan from the planner.
  2. Use List Files to inspect project structure if relevant.
  3. Use the Search Tool to identify relevant files, adjusting search queries to refine results. **Aim to batch requests for related files wherever possible, so that you can process multiple files concurrently.**
  4. Use the File Info tool to obtain specific details from each file. **When you identify multiple relevant files, make simultaneous requests for their details to maximize efficiency.**
  4. Use File Info to obtain specific details in promising files, clarifying focus with each question.
  5. Repeat steps as needed; consult Planner for adjustments if results are unclear.

  To be clear, you are expected to use the planner_tool MULTIPLE TIMES per user
  request to ensure that your investigation remains on track. Always check your
  assumptions with the planner.

  **Plan to request details from multiple files at once whenever feasible,
  reducing round trips and expediting your answer.**

  Narrow your search criteria as needed to delve into different aspects of the
  user's question, requesting information about individual functions, module
  names, phrases, etc.

  Use this process as many times as you like in order to ensure that you do not
  omit important details that you might not have found on earlier passes.

  ALWAYS consult the planner as a last step before providing your final answer.

  # Response
  By default, answer as tersely as possible. Increase your verbosity in
  proportion to the specificity of the question, but your highest priority is
  accuracy and completeness. Include code citations or examples as appropriate.

  NEVER include details that cannot be confirmed by example or citation within
  the research you performed. ALL informatin must be clearly tied to information
  you gathered in your research.

  When asked how to perform a task, ensure that your response includes concrete
  steps, including example code to illustrate the process.

  Once you have all of the context required to answer the user's question fully
  and completely, provide a concise yet complete answer. Finish your reply with
  a list of relevant files, each with 1-2 sentences explaining how they relate
  to the user's question.

  Just a reminder... did you remember to consult the planner before finalizing
  your answer?

  Format:

  # SYNOPSIS

  <restate the user's question briefly, then provide a tl;dr of your findings as a list>

  # ANSWER

  <provide the best answer here with any key details, plus relevant code snippets if required>

  # STEPS

  <summarize key steps in the investigation, focusing on major discoveries and any key choices made; also note anything unexpected that you discovered>

  # FILES

  <summarize each file's relevance in a few words (e.g., "file1.py - Main logic for X"); omit unrelated files >
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
    UI.start_link()

    status_id = UI.add_status("Researching", agent.opts.question)

    agent = send_request(agent)

    UI.complete_status(status_id, :ok)

    {:ok, agent.response}
  end

  defp send_request(agent) do
    agent
    |> build_request()
    |> get_response(agent)
    |> handle_response(agent)
  end

  defp build_request(agent) do
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

  def handle_tool_call(agent, %{
        "id" => id,
        "function" => %{
          "name" => func,
          "arguments" => args_json
        }
      }) do
    with {:ok, args} <- Jason.decode(args_json),
         {:ok, output} <- perform_tool_call(agent, func, args) do
      request = AI.Util.assistant_tool_msg(id, func, args_json)
      response = AI.Util.tool_msg(id, func, output)
      {:ok, [request, response]}
    else
      {:error, reason} ->
        IO.puts(
          :stderr,
          "Error handling tool call | #{func} -> #{args_json} | #{inspect(reason)}"
        )

        {:error, reason}
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
  defp perform_tool_call(agent, "planner_tool", _args), do: AI.Tools.Planner.call(agent, [])
  defp perform_tool_call(_agent, func, _args), do: {:error, :unhandled_tool_call, func}
end
