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

  @doc """
  Cosine similarity between two equal-length vectors. Returns 0.0 when either
  vector is zero-magnitude or the inputs differ in length.
  """
  @spec cosine_similarity(embedding(), embedding()) :: float()
  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    cond do
      a == [] or b == [] -> 0.0
      length(a) != length(b) -> 0.0
      true -> do_cosine(a, b)
    end
  end

  defp do_cosine(a, b) do
    {dot, mag_a, mag_b} =
      Enum.zip_reduce(a, b, {0.0, 0.0, 0.0}, fn x, y, {d, ma, mb} ->
        {d + x * y, ma + x * x, mb + y * y}
      end)

    if mag_a == 0.0 or mag_b == 0.0 do
      0.0
    else
      dot / (:math.sqrt(mag_a) * :math.sqrt(mag_b))
    end
  end
end
