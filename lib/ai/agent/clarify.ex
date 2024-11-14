defmodule AI.Agent.Clarify do
  @model "gpt-4o"

  @prompt """
  You are the Clarification Agent. Your job is to determine what exactly the
  user is asking for when they provide a vague or ambiguous question to help
  the Answers Agent in its research.

  You cannot directly interact with the user. Instead, you must rely on your
  tools to analyze the code base and attempt to gain enough context to
  understand the user's question.

  Pay special attention to ambigious terms or phrases that could have multiple
  meanings. Ensure that you clarify these ambiguities through research, and use
  the other terms in the user's question to ensure that your answer correlates
  with both the user's intent and the code itself.

  # Tools
  - List Files Tool: Use this tool to list all files in the project database.
  - Search Tool: Use this tool to identify relevant files using semantic queries.
  - File Info Tool: Use this tool to ask specialized questions about the contents of a specific file.

  # Response
  Respond with a detailed explanation of the user's question, along with a
  summary of your research, citing specific files or code snippets that support
  your understanding of the user's query. Ensure to clarify that ambiguities
  you discovered (for example, two unrelated entities that have similar names)
  to ensure that the Answers Agent is aware of the potential for confusion.
  """

  defstruct [
    :ai,
    :opts,
    :tool_calls,
    :messages,
    :response
  ]

  def new(ai, opts) do
    %__MODULE__{
      ai: ai,
      opts: opts,
      tool_calls: [],
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(opts.question)
      ],
      response: nil
    }
  end

  def perform(agent) do
    agent
    |> send_request()
    |> then(fn agent -> {:ok, agent.response} end)
  end

  defp send_request(agent) do
    agent
    |> build_request()
    |> get_response(agent)
    |> handle_response(agent)
  end

  defp build_request(agent) do
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
  defp perform_tool_call(_agent, func, _args), do: {:error, :unhandled_tool_call, func}
end
