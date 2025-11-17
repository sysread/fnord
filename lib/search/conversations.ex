defmodule Search.Conversations do
  @moduledoc """
  Semantic search over indexed conversations.

  This module uses conversation embeddings stored via
  `Store.Project.ConversationIndex` to find relevant conversations for a
  natural language query.
  """

  alias Store.Project
  alias Store.Project.Conversation
  alias Store.Project.ConversationIndex

  @default_limit 5

  @spec search(Project.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(%Project{} = project, query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, query_vec} <- Indexer.impl().get_embeddings(query) do
      project
      |> ConversationIndex.all_embeddings()
      |> Util.async_stream(fn {id, emb_vec, _meta} ->
        score = AI.Util.cosine_similarity(query_vec, emb_vec)
        build_result(project, id, score)
      end)
      |> Enum.reduce([], fn
        {:ok, nil}, acc -> acc
        {:ok, result}, acc -> [result | acc]
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)
      |> then(&{:ok, &1})
    end
  end

  defp build_result(project, id, score) do
    convo = Conversation.new(id, project)

    if Conversation.exists?(convo) do
      ts = Conversation.timestamp(convo)
      title = unwrap_question(Conversation.question(convo))
      length = Conversation.num_messages(convo)

      %{
        conversation_id: id,
        title: title,
        timestamp: ts,
        length: length,
        score: score
      }
    else
      nil
    end
  end

  defp unwrap_question({:ok, q}), do: q
  defp unwrap_question(_), do: "(no user question found)"
end
