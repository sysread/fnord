defmodule Chat do
  defstruct [
    :opts,
    :ai,
    :assistant_id,
    :next_asst_msg_box_id
  ]

  @doc """
  Create a new chat instance.
  """
  def new(opts) do
    ai = AI.new()

    with {:ok, %{"id" => assistant_id}} <- Assistant.get(ai) do
      %Chat{
        opts: opts,
        ai: ai,
        assistant_id: assistant_id
      }
    end
  end

  # -----------------------------------------------------------------------------
  # Chat loop
  # -----------------------------------------------------------------------------
  @doc """
  Runs the chat loop. Exits on Control-C.
  """
  def run(chat) do
    if is_nil(chat.next_asst_msg_box_id) do
      Owl.IO.puts(Owl.Data.tag("Chatting with the assistant. Control-C exits.", [:cyan, :bright]))
    end

    chat_loop(chat)
  end

  defp chat_loop(chat) do
    with {:ok, %{"id" => thread_id}} <- AI.start_thread(chat.ai) do
      # Get the user's message and add it to the thread.
      message = user_message_prompt(chat)

      # Update chat with the id of the current assistant message box.
      chat = add_assistant_message(chat, "Sending your message...")

      # Attach the user's message and run the thread
      with {:ok, _} <- AI.add_user_message(chat.ai, thread_id, message),
           {:ok, :done} <- run_thread(chat, thread_id),
           {:ok, msgs} <- AI.get_messages(chat.ai, thread_id) do
        msgs
        |> Map.get("data", [])
        |> Enum.filter(fn %{"role" => role} -> role == "assistant" end)
        |> Enum.each(fn %{"content" => [%{"text" => %{"value" => message}}]} ->
          update_assistant_message(chat, message)
        end)
      end
    end

    Process.sleep(200)
    chat_loop(chat)
  end

  # -----------------------------------------------------------------------------
  # Threads and runs
  # -----------------------------------------------------------------------------
  defp run_thread(chat, thread_id) do
    with {:ok, %{"id" => run_id}} <- AI.run_thread(chat.ai, chat.assistant_id, thread_id) do
      run_thread(chat, thread_id, run_id)
    end
  end

  defp run_thread(chat, thread_id, run_id) do
    case AI.get_run_status(chat.ai, thread_id, run_id) do
      {:ok, %{"status" => "queued"}} ->
        update_assistant_message(chat, "Assistant is typing...")
        run_thread(chat, thread_id, run_id)

      {:ok, %{"status" => "in_progress"}} ->
        update_assistant_message(chat, "Assistant is typing...")
        run_thread(chat, thread_id, run_id)

      # Requires action; most likely a tool call request
      {:ok, %{"status" => "requires_action"} = status} ->
        update_assistant_message(chat, "Researching project...")
        outputs = get_tool_outputs(chat, status)

        case AI.submit_tool_outputs(chat.ai, thread_id, run_id, outputs) do
          {:ok, _} -> run_thread(chat, thread_id, run_id)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{"status" => "completed"}} ->
        update_assistant_message(chat, "Formatting response...")
        {:ok, :done}

      {:ok, status} ->
        update_assistant_message(chat, "Error! API response:\n\n#{inspect(status)}")
        {:error, :failed}

      {:error, reason} ->
        update_assistant_message(chat, "Error! API response:\n\n#{inspect(reason)}")
        {:error, reason}
    end
  end

  # -----------------------------------------------------------------------------
  # Tool calls
  # -----------------------------------------------------------------------------
  defp get_tool_outputs(chat, run_status) do
    run_status
    |> Map.get("required_action", %{})
    |> Map.get("submit_tool_outputs", %{})
    |> Map.get("tool_calls", [])
    |> Enum.map(&get_tool_call_output(chat, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp get_tool_call_output(
         chat,
         %{
           "id" => id,
           "function" => %{
             "name" => "search_tool",
             "arguments" => json_args_string
           }
         }
       ) do
    %{"query" => query} = Jason.decode!(json_args_string)

    update_assistant_message(chat, "Searching for: #{query}")

    {:ok, results} =
      chat.opts
      |> Map.put(:detail, true)
      |> Map.put(:limit, 5)
      |> Map.put(:query, query)
      |> Search.new()
      |> Search.get_results()
      |> Enum.map(fn {file, score, data} ->
        """
        -----
        # File: #{file} | Score: #{score}
        #{data["summary"]}
        """
      end)
      |> Enum.join("\n")
      |> then(fn res -> {:ok, res} end)

    %{tool_call_id: id, output: results}
  end

  defp get_tool_call_output(_chat, _status), do: nil

  # -----------------------------------------------------------------------------
  # UI
  # -----------------------------------------------------------------------------
  defp user_message_prompt(_chat) do
    Owl.IO.input(label: "Enter your message:")
  end

  defp add_assistant_message(chat, message) do
    id = Base.encode16(:crypto.strong_rand_bytes(8))

    Owl.LiveScreen.add_block(id,
      state:
        Owl.Box.new(message,
          title: " Assistant ",
          border_style: :solid_rounded,
          border_tag: :cyan,
          padding: 1,
          min_height: 1,
          min_width: 140,
          max_width: 140,
          horizontal_align: :left,
          vertical_align: :top,
          word_wrap: :normal
        )
    )

    %Chat{chat | next_asst_msg_box_id: id}
  end

  defp update_assistant_message(chat, message) do
    Owl.LiveScreen.update(
      chat.next_asst_msg_box_id,
      Owl.Box.new(message,
        title: " Assistant ",
        border_style: :solid_rounded,
        border_tag: :cyan,
        padding: 1,
        min_height: 1,
        min_width: 140,
        max_width: 140,
        horizontal_align: :left,
        vertical_align: :top,
        word_wrap: :normal
      )
    )

    Owl.LiveScreen.await_render()
  end
end
