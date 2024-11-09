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
    :tool_call,
    :messages
  ])

  @model "gpt-4o"

  @prompt """
  You are a conversational interface to a database of information about the
  user's project. The database may contain:

  ### Code files:
    - **Synopsis**
    - **Languages present in the file**
    - **Business logic and behaviors**
    - **List of symbols**
    - **Map of calls to other modules**

  ### Documentation files (e.g., README, wiki pages, general documentation):
    - **Synopsis**: A brief overview of what the document covers.
    - **Topics and Sections**: A list of main topics or sections in the document.
    - **Definitions and Key Terms**: Any specialized terms or jargon defined in the document.
    - **Links and References**: Important links or references included in the document.
    - **Key Points and Highlights**: Main points or takeaways from the document.

  The user will prompt you with a question. You will use your `search_tool` to
  search the database in order to gain enough knowledge to answer the question
  as completely as possible. It may require multiple searches before you have
  all of the information you need.

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

  @search_tool %{
    type: "function",
    function: %{
      name: "search_tool",
      description: "searches for matching files and their contents",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The search query string."
          }
        },
        required: ["query"]
      }
    }
  }

  @tool_call %{
    id: nil,
    func: "",
    args: "",
    output: ""
  }

  def new(ai, opts, callback) do
    %AI.Agent.Answers{
      ai: ai,
      opts: opts,
      callback: callback,
      last_msg_chunk: "",
      msg_buffer: "",
      tool_call: @tool_call,
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
    %AI.Agent.Answers{agent | msg_buffer: "", last_msg_chunk: "", tool_call: @tool_call}
  end

  # -----------------------------------------------------------------------------
  # Stream processing
  # -----------------------------------------------------------------------------
  defp send_request(%{msg_buffer: "", tool_call: @tool_call} = agent) do
    Ask.update_status("Talking to the assistant")

    agent.ai
    |> get_response_stream(agent.messages)
    |> process_stream(agent)
  end

  defp send_request(agent) do
    agent.ai
    |> get_response_stream(agent.messages)
    |> process_stream(agent |> reset_buffers())
  end

  defp get_response_stream(ai, messages) do
    chat_req =
      OpenaiEx.Chat.Completions.new(
        model: @model,
        tools: [@search_tool],
        tool_choice: "auto",
        messages: messages
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
      agent.tool_call
      |> Map.put(:id, id)
      |> Map.put(:func, name)

    %AI.Agent.Answers{agent | tool_call: tool_call}
  end

  # Collect tool call fragments (both "name" and "arguments")
  defp handle_response(agent, %{"delta" => %{"tool_calls" => [%{"function" => frag}]}}) do
    Ask.update_status("Assistant is preparing a search...")

    # Extract fragments of "id", "name", and "arguments" if they exist
    name_frag = Map.get(frag, "name", "")
    args_frag = Map.get(frag, "arguments", "")

    # Accumulate the fragments into the tool call
    tool_call =
      agent.tool_call
      |> Map.update!(:func, &(&1 <> name_frag))
      |> Map.update!(:args, &(&1 <> args_frag))

    %AI.Agent.Answers{agent | tool_call: tool_call}
  end

  # Handle the completion of tool calls
  defp handle_response(agent, %{"finish_reason" => "tool_calls"}) do
    Ask.update_status("Assistant requested search results")

    with {:ok, output} <- handle_tool_call(agent) do
      tool_request =
        assistant_tool_message(
          agent.tool_call.id,
          agent.tool_call.func,
          agent.tool_call.args
        )

      tool_response =
        tool_message(
          agent.tool_call.id,
          agent.tool_call.func,
          output
        )

      messages = agent.messages ++ [tool_request, tool_response]

      %AI.Agent.Answers{
        agent
        | messages: messages,
          tool_call: %{agent.tool_call | output: output}
      }
      |> send_request()
    end
  end

  # Catch-all for unhandled events
  defp handle_response(agent, event) do
    IO.inspect(event, label: "UNHANDLED")
    agent
  end

  # -----------------------------------------------------------------------------
  # Search tool
  # -----------------------------------------------------------------------------
  defp handle_tool_call(%{tool_call: %{func: "search_tool", args: args_json}} = agent) do
    with {:ok, args} <- Jason.decode(args_json),
         {:ok, query} <- Map.fetch(args, "query"),
         {:ok, results} <- search_tool(agent, query) do
      results
      |> Enum.join("\n\n")
      |> then(&{:ok, &1})
    end
  end

  defp handle_tool_call(_agent) do
    {:error, :unhandled_tool_call}
  end

  defp search_tool(agent, search_query) do
    AI.Agent.Search.new(
      agent.ai,
      agent.opts.question,
      search_query,
      agent.opts
    )
    |> AI.Agent.Search.search()
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
