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
    :response,
    :token_status_id
  ])

  @model "gpt-4o"

  @max_tokens 128_000

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
  The project database contains summaries of each file within the project. Use
  this tool with a query optimized for a vector database of file embeddings
  based on summaries of each file's contents.

  ## File Info Tool
  Code and documentation may be too large for your context window. Use this
  tool to ask an AI agent specific questions about promising files in the
  project that may contain information you need. Craft questions so that the AI
  agent returns the specifics you need. For example, ask it to cite code
  fragments and functions relevant to your question about the file.

  This tool provides better information when you ask it narrower, more specific
  questions.

  # Process
  Batch tool call requests wherever possible to process multiple files concurrently.

  1. Use List Files to inspect project structure if relevant.
  2. Get an initial plan from the Planner.
  3. Use Search Tool to identify relevant files, adjusting search queries to refine results.
  4. Use File Info to obtain specific details in promising files, clarifying focus with each question.

  Repeat steps as needed; consult Planner for adjustments if your research is
  unclear.

  # Response
  By default, answer as tersely as possible. Increase verbosity in proportion
  to the question's specificity, but prioritize accuracy and completeness.
  Include code citations or examples as appropriate.

  NEVER include unconfirmed details. Tie all information clearly to research
  you performed. Conclude with a list of relevant files, each with 1-2
  sentences on how they relate to the user's question.

  Format:

  # SYNOPSIS

  <restate the user's question briefly, then provide a tl;dr of your findings as a list>

  # ANSWER

  <provide the best answer here with any key details, plus relevant code snippets if required>

  # FILES

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
    UI.start_link()
    UI.add_token_usage(@max_tokens)
    status_id = UI.add_status("Researching", Owl.Data.tag(agent.opts.question, :bright))

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
      status_id = UI.add_status("Defragmenting conversation (#{length(agent.messages)} messages)")
      {:ok, pre_tokens} = get_context_window_usage(agent)

      with {:ok, msgs} <- AI.Agent.Defrag.summarize_findings(agent) do
        {:ok, post_tokens} = get_context_window_usage(agent)
        dropped = pre_tokens - post_tokens

        status = "#{length(msgs)} messages; reduced by #{dropped} tokens"
        UI.complete_status(status_id, :ok, status)

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
