defmodule AI.Agent.Embeddings do
  @moduledoc """
  This module provides an agent that generates embeddings for text data.
  """

  @token_limit 8192

  @model "text-embedding-3-large"

  @doc """
  Get embeddings for the given text. The text is split into chunks of 8192
  tokens to avoid exceeding the model's input limit. Returns a list of
  embeddings for each chunk.
  """
  def get_embeddings(ai, text) do
    embeddings =
      AI.Util.split_text(text, @token_limit)
      |> Enum.map(fn chunk ->
        OpenaiEx.Embeddings.create(
          ai.client,
          OpenaiEx.Embeddings.new(model: @model, input: chunk)
        )
        |> case do
          {:ok, %{"data" => [%{"embedding" => embedding}]}} -> embedding
          _ -> nil
        end
      end)
      |> Enum.filter(fn x -> not is_nil(x) end)

    {:ok, embeddings}
  end
end
