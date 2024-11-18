defmodule AI.Agent.TagRunner do
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
  You are the Tag Runner Agent.
  You are a code spelunker, digging through "outlines" (representations of code files as symbols and their relationships) to trace paths through the code base on behalf of the Answers Agent, who interacts with the user.
  You will assist the Answers Agent in answering questions about the code base by following the path from one symbol to another or by identifying files and assembling a call back to a particular symbol.
  You will use these outlines to navigate code files, tracing paths through the code in order to assist the Answers Agent in correctly answering the user's questions about the code base.

  # Procedures:

  ## Callees
  - Use the `outline_tool` to retrieve an outline of symbols and calls in the start file
  - Depending on the Answers Agent's question, you may need to make use of your other tools to learn about the callees
  - Respond with a summary of the callees
    - If the outline detailed conditions under which callees are called, include those details
    - If the question required additional information about the callees, include the information you found using your other tools

  ## Callers
  - Use the `search` tool to retrieve a list of files that might contain the symbol in question; for best results, search only for the module/class name and symbol name
  - Use the `outline_tool` to retrieve an outline of symbols and calls in the start file
  - Respond with a summary of the callers
    - If the outlines detailed conditions under which callers are called, include those details
    - If the question required additional information about the callers, include the information you found using your other tools

  ## Trace path **to** a symbol in the start file
  - Use the `Callers` procedure, recursively tracing backwards until you believe you have reached either the beginning of any call chain or have run out of callers
  - Respond with an organized list tracing each possible path to a symbol, including any conditional logic that applies
    - For example, if you are tracing paths to `Quux.quuz()`:
      - `Foo.bar() -> Baz.qux() -> Quux.quuz()`
      - `Blargh.blargh() -> Quux.quuz()`
      - `Quux.quuz()` -> `Quux.quuz()` (when the argument is a list)

  ## Trace path **from** a symbol in the start file
  - Use the `Callees` procedure, recursively tracing forwards until you believe you have reached either the end of any call chain or have run out of callees
  - Respond with an organized list tracing each possible path from a symbol, including any conditional logic that applies
    - For example, if you are tracing paths from `Foo.bar()`:
      - `Foo.bar() -> Baz.qux() -> Quux.quuz()`
      - `Foo.bar() -> Quux.quuz()`
      - `Foo.bar() -> Foo.bar()` (when the argument is a list)

  ## Trace all possible paths between two symbols
  - Combine your other tracing procedures logically to trace all possible paths between two symbols
  - Respond with an organized list of all possible paths between the two symbols, including any conditional logic that applies, **including** the steps you took to arrive at the answer

  ## Oddball requests
  - Do your best to reason out a logical procedure to identify the requested information, paying careful attention to the Answers Agent's question
  - Ensure that you are working in the correct direction from the source symbol in the start file
  - Respond as appropriate to the question, providing as much detail as you can, **including** the steps you took to arrive at the answer
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
        AI.Tools.GetOutline.spec()
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
  defp perform_tool_call(agent, "outline_tool", args), do: AI.Tools.GetOutline.call(agent, args)
  defp perform_tool_call(_agent, func, _args), do: {:error, :unhandled_tool_call, func}
end
