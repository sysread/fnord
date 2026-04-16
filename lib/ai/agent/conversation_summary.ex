defmodule AI.Agent.ConversationSummary do
  @moduledoc """
  Summarizes a conversation transcript for embedding generation.

  Produces a concise natural-language summary that captures the topics
  discussed, decisions made, and key outcomes. The summary is used as
  input to the embedding model for semantic search over conversations.
  """

  @model AI.Model.fast()

  @prompt """
  You are summarizing a conversation between a user and an AI assistant for semantic search indexing.

  Produce a concise summary covering:
  - The primary topics and questions discussed
  - Key decisions, conclusions, or outcomes reached
  - Notable code, files, or systems referenced
  - Any unresolved questions or next steps mentioned

  Write in plain, descriptive prose. Optimize for semantic search: someone searching
  for a conversation about topic X should find this summary if that topic was discussed.
  Keep your response brief - aim for a few paragraphs at most.
  Do not include conversational filler or meta-commentary about the summarization process.
  """

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    case Map.fetch(opts, :transcript) do
      {:ok, transcript} ->
        AI.Accumulator.get_response(
          model: @model,
          prompt: @prompt,
          input: transcript,
          question: "Summarize this conversation for search indexing."
        )
        |> case do
          {:ok, %{response: response}} -> {:ok, response}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :transcript_required}
    end
  end
end
