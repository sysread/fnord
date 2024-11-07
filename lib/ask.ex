defmodule Ask do
  defstruct [
    :opts,
    :ai,
    :question,
    :matched_files,
    :tool_call,
    :buffer,
    :last_chunk,
    :messages
  ]

  @tool_call_acc %{
    id: "",
    func: "",
    args: "",
    output: ""
  }

  def new(opts) do
    %Ask{
      opts: opts,
      ai: AI.new(),
      question: opts.question,
      matched_files: [],
      tool_call: @tool_call_acc,
      buffer: "",
      last_chunk: "",
      messages: [
        AI.system_message(),
        AI.user_message(opts.question)
      ]
    }
  end

  def run(ask) do
    ask
    |> start_output()
    |> send_request()
    |> end_output()
  end

  def reset_buffers(ask) do
    %Ask{ask | buffer: "", last_chunk: "", tool_call: @tool_call_acc}
  end

  defp start_output(%Ask{opts: %{quiet: true}} = ask) do
    ask
  end

  defp start_output(ask) do
    Owl.LiveScreen.add_block(:answer, state: "Assistant is thinking...")
    ask
  end

  defp output(%Ask{opts: %{quiet: true}, last_chunk: data} = ask) do
    IO.write(data)
    ask
  end

  defp output(ask) do
    Owl.LiveScreen.update(:answer, ask.buffer)
    Owl.LiveScreen.await_render()
    ask
  end

  defp end_output(%Ask{opts: %{quiet: true}} = ask) do
    IO.puts("")
    ask
  end

  defp end_output(ask) do
    Owl.IO.puts("")
    ask
  end

  # -----------------------------------------------------------------------------
  # Stream processing
  # -----------------------------------------------------------------------------
  def send_request(%{buffer: "", tool_call: @tool_call_acc} = ask) do
    ask.ai
    |> AI.stream(ask.messages)
    |> process_stream(ask)
  end

  def send_request(ask) do
    ask.ai
    |> AI.stream(ask.messages)
    |> process_stream(ask |> reset_buffers())
  end

  defp process_stream(stream, ask) do
    stream
    |> Stream.flat_map(& &1)
    |> Enum.reduce(ask, fn event, ask ->
      handle_response(ask, event)
    end)
  end

  # -----------------------------------------------------------------------------
  # General event handling
  # -----------------------------------------------------------------------------
  # Strip out the :data and "choices" wrappers
  defp handle_response(ask, %{data: %{"choices" => event}}) do
    handle_response(ask, event)
  end

  # -----------------------------------------------------------------------------
  # Message events
  # -----------------------------------------------------------------------------
  # The message is complete
  defp handle_response(ask, [%{"finish_reason" => "stop"}]) do
    %Ask{ask | messages: ask.messages ++ [AI.assistant_message(ask.buffer)]}
    |> reset_buffers()
  end

  # Extract the message content
  defp handle_response(ask, [%{"delta" => %{"content" => content}}])
       when not is_nil(content) do
    %Ask{ask | last_chunk: content, buffer: ask.buffer <> content}
    |> output()
  end

  # -----------------------------------------------------------------------------
  # Tool call events
  # -----------------------------------------------------------------------------
  defp handle_response(ask, [
         %{
           "delta" => %{
             "tool_calls" => [
               %{"id" => id, "function" => %{"name" => name}}
             ]
           }
         }
       ]) do
    tool_call =
      ask.tool_call
      |> Map.put(:id, id)
      |> Map.put(:func, name)

    %Ask{ask | tool_call: tool_call}
  end

  # Collect tool call fragments (both "name" and "arguments")
  defp handle_response(ask, [%{"delta" => %{"tool_calls" => [%{"function" => frag}]}}]) do
    # Extract fragments of "id", "name", and "arguments" if they exist
    name_frag = Map.get(frag, "name", "")
    args_frag = Map.get(frag, "arguments", "")

    # Accumulate the fragments into the tool call
    tool_call =
      ask.tool_call
      |> Map.update!(:func, &(&1 <> name_frag))
      |> Map.update!(:args, &(&1 <> args_frag))

    %Ask{ask | tool_call: tool_call}
  end

  # Handle the completion of tool calls
  defp handle_response(ask, [%{"finish_reason" => "tool_calls"}]) do
    with {:ok, output} <- handle_tool_call(ask) do
      tool_request =
        AI.assistant_tool_message(
          ask.tool_call.id,
          ask.tool_call.func,
          ask.tool_call.args
        )

      tool_response = AI.tool_message(ask.tool_call.id, ask.tool_call.func, output)
      messages = ask.messages ++ [tool_request, tool_response]

      %Ask{ask | messages: messages, tool_call: %{ask.tool_call | output: output}}
      |> send_request()
    end
  end

  # Catch-all for unhandled events
  defp handle_response(ask, event) do
    IO.inspect(event, label: "UNHANDLED")
    ask
  end

  # -----------------------------------------------------------------------------
  # Tool call outputs
  # -----------------------------------------------------------------------------
  # Function to execute the tool call
  defp handle_tool_call(%{tool_call: %{func: "search_tool", args: args_json}} = ask) do
    with {:ok, args} <- Jason.decode(args_json),
         {:ok, query} <- Map.fetch(args, "query") do
      ask.opts
      |> Map.put(:concurrency, ask.opts.concurrency)
      |> Map.put(:detail, true)
      |> Map.put(:limit, 10)
      |> Map.put(:query, query)
      |> Search.new()
      |> Search.get_results()
      |> Enum.map(fn {file, score, data} ->
        """
        -----
        # File: #{file} | Score: #{score}

        ## Summary
        #{data["summary"]}
        ```
        """
      end)
      |> Enum.join("\n")
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :query_not_found}
    end
  end

  defp handle_tool_call(_ask) do
    {:error, :unhandled_tool_call}
  end
end
