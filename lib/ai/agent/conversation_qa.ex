defmodule AI.Agent.ConversationQA do
  @behaviour AI.Agent

  @model AI.Model.large_context()

  @system_prompt """
  You answer questions about a previous fnord conversation.
  Use only the provided conversation messages as your source of truth.
  When uncertain, say so rather than inventing details.
  """

  @spec get_response(map()) :: {:ok, String.t()} | {:error, term()}
  def get_response(%{agent: agent, conversation_id: id, question: question}) do
    with {:ok, project} <- Store.get_project(),
         {:ok, convo} <- load_conversation(project, id) do
      messages = build_messages(convo, question)

      case AI.Agent.get_completion(agent,
        model: @model,
        messages: messages,
        toolbox: %{}
      ) do
        {:ok, %AI.Completion{response: response}} when is_binary(response) ->
          {:ok, response}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def get_response(_), do: {:error, :invalid_arguments}

  defp load_conversation(project, id) do
    conversation = Store.Project.Conversation.new(id, project)

    if Store.Project.Conversation.exists?(conversation) do
      {:ok, _ts, messages, metadata} = Store.Project.Conversation.read(conversation)
      {:ok, %{id: id, messages: messages, metadata: metadata}}
    else
      {:error, :conversation_not_found}
    end
  end

  defp build_messages(convo, question) do
    json = Jason.encode!(%{"messages" => convo.messages})

    [
      AI.Util.system_msg(@system_prompt),
      AI.Util.user_msg("""
      Here is a previous conversation as JSON:

      #{json}

      My question about this conversation: #{question}
      """)
    ]
  end
end
