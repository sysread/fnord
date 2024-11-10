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
    :callback,
    :last_msg_chunk,
    :msg_buffer,
    :tool_calls,
    :messages
  ])

  @model "gpt-4o"

  @prompt """
  You are a conversational interface to a database of information about the
  user's project.

  Your database may contain:
  - Code: synopsis, languages, business logic, symbols, and external calls
  - Docs: synopsis, topics, definitions, links, references, key points, and highlights

  Tools available to you:
  - list_files_tool: List all files in the project database
  - search_tool: Search for phrases in the project embeddings database as many
  times as you need to ensure you have all of the context required to answer
  the user's question fully

  Once you have all of the information you need, provide the user with a
  complete yet concise answer, including generating any requested code or
  producing on-demand documentation by assimilating the information you have
  gathered.

  By default, answer as tersely as possible. Increase your verbosity in
  proportion to the specificity of the question.

  ALWAYS finish your response with a list of the relevant files that you found.
  Exclude files that are not relevant to the user's question. Format them as a
  list, where each file name is bolded and is followed by a colon and an
  explanation of how it is relevant. Err on the side of inclusion if you are
  unsure.
  """

  @tool_call %{
    id: nil,
    func: "",
    args: ""
  }

  def new(ai, opts, callback) do
    %AI.Agent.Answers{
      ai: ai,
      opts: opts,
      callback: callback,
      last_msg_chunk: "",
      msg_buffer: "",
      tool_calls: [],
      messages: [
        system_message(),
        user_message(opts.question)
      ]
    }
  end

  def perform(agent) do
    send_request(agent)
  end

  defp reset_buffers(agent) do
    %AI.Agent.Answers{agent | msg_buffer: "", last_msg_chunk: "", tool_calls: []}
  end

  # -----------------------------------------------------------------------------
  # Stream processing
  # -----------------------------------------------------------------------------
  defp send_request(agent) do
    Ask.update_status("Talking to the assistant")

    agent.ai
    |> get_response_stream(agent.messages)
    |> process_stream(agent |> reset_buffers())
  end

  defp get_response_stream(ai, messages) do
    chat_req =
      OpenaiEx.Chat.Completions.new(
        model: @model,
        tool_choice: "auto",
        messages: messages,
        tools: [
          AI.Tools.Search.spec(),
          AI.Tools.ListFiles.spec()
        ]
      )

    {:ok, chat_stream} =
      OpenaiEx.Chat.Completions.create(
        ai.client,
        chat_req,
        stream: true
      )

    chat_stream.body_stream
  end

  defp process_stream(stream, agent) do
    stream
    |> Stream.flat_map(& &1)
    |> Stream.map(fn %{data: %{"choices" => [event]}} -> event end)
    |> Enum.reduce(agent, fn event, agent ->
      handle_response(agent, event)
    end)
  end

  # -----------------------------------------------------------------------------
  # Message events
  # -----------------------------------------------------------------------------
  # The message is complete
  defp handle_response(agent, %{"finish_reason" => "stop"}) do
    Ask.update_status("Answer received")

    %AI.Agent.Answers{agent | messages: agent.messages ++ [assistant_message(agent.msg_buffer)]}
    |> reset_buffers()
  end

  # Extract the message content
  defp handle_response(agent, %{"delta" => %{"content" => content}})
       when is_binary(content) do
    Ask.update_status("Assistant is typing...")

    agent = %AI.Agent.Answers{
      agent
      | last_msg_chunk: content,
        msg_buffer: agent.msg_buffer <> content
    }

    agent.callback.(content, agent.msg_buffer)
    agent
  end

  # -----------------------------------------------------------------------------
  # Tool call events
  # -----------------------------------------------------------------------------
  # THe initial response contains the function and tool call ID
  defp handle_response(agent, %{
         "delta" => %{
           "tool_calls" => [
             %{"id" => id, "function" => %{"name" => name}}
           ]
         }
       }) do
    Ask.update_status("Assistant is preparing a search...")

    tool_call =
      @tool_call
      |> Map.put(:id, id)
      |> Map.put(:func, name)

    tool_calls = [tool_call | agent.tool_calls]

    %AI.Agent.Answers{agent | tool_calls: tool_calls}
  end

  # Collect tool call fragments (both "name" and "arguments")
  defp handle_response(agent, %{"delta" => %{"tool_calls" => [%{"function" => frag}]}}) do
    Ask.update_status("Assistant is preparing a search...")

    # Extract fragments of "id", "name", and "arguments" if they exist
    name_frag = Map.get(frag, "name", "")
    args_frag = Map.get(frag, "arguments", "")

    {[tool_call], tool_calls} = Enum.split(agent.tool_calls, 1)

    # Accumulate the fragments into the tool call
    tool_call =
      tool_call
      |> Map.update!(:func, &(&1 <> name_frag))
      |> Map.update!(:args, &(&1 <> args_frag))

    %AI.Agent.Answers{agent | tool_calls: [tool_call | tool_calls]}
  end

  # Handle the completion of tool calls
  defp handle_response(agent, %{"finish_reason" => "tool_calls"}) do
    Ask.update_status("Assistant requested search results")

    agent
    |> handle_tool_calls()
    |> send_request()
  end

  # -----------------------------------------------------------------------------
  # Catch-all for unhandled events
  # -----------------------------------------------------------------------------
  defp handle_response(agent, _event) do
    agent
  end

  # -----------------------------------------------------------------------------
  # Tool calls
  # -----------------------------------------------------------------------------
  defp handle_tool_calls(%{tool_calls: []} = agent) do
    agent
  end

  defp handle_tool_calls(%{tool_calls: [tool_call | remaining]} = agent) do
    with {:ok, agent} <- handle_tool_call(agent, tool_call) do
      %AI.Agent.Answers{agent | tool_calls: remaining}
      |> handle_tool_calls()
    end
  end

  defp handle_tool_call(agent, %{id: id, func: func, args: args_json}) do
    with {:ok, args} <- Jason.decode(args_json),
         {:ok, output} <- perform_tool_call(agent, func, args) do
      request = assistant_tool_message(id, func, args_json)
      response = tool_message(id, func, output)
      {:ok, %AI.Agent.Answers{agent | messages: agent.messages ++ [request, response]}}
    end
  end

  defp perform_tool_call(agent, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json) do
      perform_tool_call(agent, func, args)
    end
  end

  defp perform_tool_call(agent, "search_tool", args) do
    AI.Tools.Search.call(agent, args)
  end

  defp perform_tool_call(agent, "list_files_tool", args) do
    AI.Tools.ListFiles.call(agent, args)
  end

  defp perform_tool_call(_agent, func, _args) do
    {:error, :unhandled_tool_call, func}
  end

  # -----------------------------------------------------------------------------
  # Message construction
  # -----------------------------------------------------------------------------
  defp system_message(), do: OpenaiEx.ChatMessage.system(@prompt)
  defp assistant_message(msg), do: OpenaiEx.ChatMessage.assistant(msg)
  defp user_message(msg), do: OpenaiEx.ChatMessage.user(msg)
  defp tool_message(id, func, output), do: OpenaiEx.ChatMessage.tool(id, func, output)

  defp assistant_tool_message(id, func, args) do
    %{
      role: "assistant",
      content: nil,
      tool_calls: [
        %{
          id: id,
          type: "function",
          function: %{
            name: func,
            arguments: args
          }
        }
      ]
    }
  end
end
