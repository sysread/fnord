defmodule AI.Agent.Spelunker do
  defstruct [
    :ai,
    :opts,
    :symbol,
    :start_file,
    :question,
    :messages,
    :response,
    :requested_tool_calls
  ]

  @model "gpt-4o"

  @prompt """
  You are the Spelunker Agent. Your job is to *thoroughly* work through maps of code symbols and function calls to *completely* trace paths through the code base.
  You are a code explorer and a graph search, digging through "outlines" (representations of code files as symbols and their relationships) to trace paths through the code base on behalf of the Answers Agent, who interacts with the user.
  You will assist the Answers Agent in answering questions about the code base by following the path from one symbol to another or by identifying files and assembling a call back to a particular symbol.
  Use the tool calls at your disposal to dig through the code base; combine multiple tool calls into a single request to perform them concurrently.
  Use your tools as many times as necessary to ensure that you have the COMPLETE picture. Do NOT respond ambiguously unless you have made multiple attempts to find the answer.
  You will use these outlines to navigate code files, tracing paths through the code in order to assist the Answers Agent in correctly answering the user's questions about the code base.
  To find callers, start with the target symbol and work backwards through the code base, alternating between the search_tool and outline_tool, until you reach a dead end or entry point. Report the paths you discovered.
  To find callees, search for the target symbol and filter based on language-specific semantics (e.g. imports, aliases, etc.) to find all references to the symbol. Report the paths you discovered.
  Your highest priority is to provide COMPLETE and ACCURATE information to the Answers Agent; ensure you have a complete code path before sending your response.
  """

  def new(ai, opts, symbol, start_file, question) do
    %__MODULE__{
      ai: ai,
      opts: opts,
      symbol: symbol,
      start_file: start_file,
      question: question,
      messages: [
        OpenaiEx.ChatMessage.system(@prompt),
        OpenaiEx.ChatMessage.user("""
        The Answers Agent has requested your assistance in tracing a path
        through the code base, beginning with the symbol `#{symbol}` in the
        file `#{start_file}`, in order to discover the answer to this question:
        `#{question}`.
        """)
      ],
      requested_tool_calls: []
    }
  end

  def trace(agent) do
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
    OpenaiEx.Chat.Completions.new(
      model: @model,
      tool_choice: "auto",
      messages: agent.messages,
      tools: [
        AI.Tools.Search.spec(),
        AI.Tools.ListFiles.spec(),
        AI.Tools.FileInfo.spec(),
        AI.Tools.Outline.spec()
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
      %__MODULE__{agent | requested_tool_calls: tool_calls}
      |> handle_tool_calls()
      |> send_request()
    end
  end

  defp handle_response({:error, %OpenaiEx.Error{message: "Request timed out."}}, agent) do
    Tui.warn("Request timed out. Retrying in 500 ms.")
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
    end
  end

  # -----------------------------------------------------------------------------
  # Tool call outputs
  # -----------------------------------------------------------------------------
  defp perform_tool_call(agent, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json),
         {:ok, output} <- perform_tool_call(agent, func, args) do
      {:ok, output}
    else
      error ->
        Tui.warn("Error handling tool call #{func}", inspect(error))
        {:ok, inspect(error)}
    end
  end

  defp perform_tool_call(agent, "search_tool", args), do: AI.Tools.Search.call(agent, args)
  defp perform_tool_call(agent, "list_files_tool", args), do: AI.Tools.ListFiles.call(agent, args)
  defp perform_tool_call(agent, "file_info_tool", args), do: AI.Tools.FileInfo.call(agent, args)
  defp perform_tool_call(agent, "outline_tool", args), do: AI.Tools.Outline.call(agent, args)
  defp perform_tool_call(_agent, func, _args), do: {:error, :unhandled_tool_call, func}
end
