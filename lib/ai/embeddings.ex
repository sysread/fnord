defmodule AI.Embeddings do
  @moduledoc """
  Embedding generation via a local sentence transformer model.

  Delegates to `AI.Embeddings.Pool`, which manages a long-lived embed.exs
  process running all-MiniLM-L12-v2 (384-dimensional vectors, mean pooling).
  """

  @model "all-MiniLM-L12-v2"
  @dimensions 384

  @doc "Returns the embedding model name."
  @spec model_name() :: String.t()
  def model_name, do: @model

  @doc "Returns the expected embedding vector dimensionality."
  @spec dimensions() :: pos_integer()
  def dimensions, do: @dimensions

  @type embedding :: list(float())

  @type error ::
          {:error, :pool_not_running}
          | {:error, :port_not_connected}
          | {:error, :port_died}
          | {:error, :timeout}
          | {:error, String.t()}

  @doc """
  Generates an embedding vector for the given text input.
  Returns `{:ok, [float()]}` with a #{@dimensions}-dimensional vector.
  """
  @spec get(String.t()) :: {:ok, embedding()} | error()
  def get(input) when is_binary(input) do
    input = String.trim(input)

    if input == "" do
      {:error, "empty input"}
    else
      AI.Embeddings.Pool.embed(input)
    end
  end
end
