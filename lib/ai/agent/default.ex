defmodule AI.Agent.Default do
  @behaviour AI.Agent

  @model AI.Model.balanced()

  @prompt """
  You are a helpful assistant.
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, prompt} <- Map.fetch(opts, :prompt),
         {:ok, response, messages} = get_completion(prompt) do
      save_conversation(messages)
      {:ok, response}
    end
  end

  defp get_completion(prompt) do
    AI.Completion.get(
      model: @model,
      tools: [AI.Tools.Default.UpdatePrompt.spec()],
      messages: build_conversation(prompt),
      log_messages: true,
      log_tool_calls: true,
      replay_conversation: false
    )
    |> case do
      {:ok, %{response: response, messages: messages}} ->
        {:ok, response, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_conversation(messages) do
    Store.DefaultProject.write_conversation(messages)
  end

  defp build_conversation(prompt) do
    new_msgs = [
      AI.Util.system_msg(@prompt),
      AI.Util.user_msg(prompt)
    ]

    with {:ok, msgs} <- Store.DefaultProject.read_conversation() do
      msgs ++ new_msgs
    else
      _ -> new_msgs
    end
  end
end
